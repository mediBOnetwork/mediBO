-- ═══════════════════════════════════════════════════════════════════════════
-- CHANGE #686 — ROUND 5. Hostile QA round 3 left three things standing after
-- round 4 took its two majors: a class of Dart source the detector still
-- accepts (R3-4), a guard that reads a trigger's PRESENCE and not its state
-- (round-2 finding 382), and five stub journeys that say
-- "TODO implement before completing #686".
--
-- The journeys are the point. A screenshot retires one row; a journey retires
-- the CLASS, and every one of these five was filed as a blocker against this
-- command. They are written here, in SQL, because dev_journey_probe is where
-- assertion logic lives (max-backend) and because every one of them is a
-- statement about the DATABASE, not about a canvas nobody can click.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. R3-4: the detector was an allowlist-by-omission ──────────────────
-- Round 3's rules catch interpolation, $ident, a fixed method-name list, the
-- null-aware operators, a leading close-bracket, a stray brace and a bare
-- dotted identifier. QA then handed over eleven shapes that are plainly Dart
-- and pass all three: 'Theme.of(context).textTheme.bodyMedium',
-- 'EdgeInsets.all(16)', 'const SizedBox(height: 8)',
-- "DateFormat('dd MMM yyyy').format(date)", 'order.total.abs()',
-- '(x) => x.name', "count > 1 ? 'items' : 'item'", "'Total: '" (a bare Dart
-- string literal, quotes and all), "'Qty: ' + qty". The method list could
-- never keep up — .format( .all( .of( .abs() .toList() .fold( .firstWhere(
-- .padLeft( were all absent — so the new rules describe SHAPES instead of
-- naming methods.
--
-- Every one of these was measured against all 6,115 live rows before it was
-- added: zero rows match, so this re-validates without an exemption. The
-- near-misses that must KEEP working were measured too and all pass:
-- 'https://company.com (optional)' (a dotted host followed by a SPACE and a
-- paren — which is why the call rule requires the paren to touch the name),
-- 'Save $5 today', 'US$ 20', "Doctor's prescription", '₹{amount}',
-- 'Loading...', and the proforma banner whose prose contains 'are final;'
-- (which is why there is no Dart-keyword rule — it flagged two real
-- sentences and caught nothing the other rules missed).
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
    -- ROUND 5 — shapes, not names:
    or p_value ~ '=>'                                -- an arrow function
    or p_value ~ '^\s*const\s'                       -- a const expression
    or p_value ~ ('\y(Theme|EdgeInsets|SizedBox|TextStyle|FontWeight'
         || '|BoxDecoration|MediaQuery|DateFormat|NumberFormat|Navigator'
         || '|BorderRadius|Colors|Icons|Duration|Offset|Alignment'
         || '|CrossAxisAlignment|MainAxisAlignment|Padding|Scaffold|InkWell'
         || '|GestureDetector)\s*[.(]')              -- a Flutter/Dart class
    or p_value ~ '[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*\('
                                                     -- any x.y( call at all
    or p_value ~ '\?\s*''[^'']*''\s*:\s*''[^'']*'''  -- a quoted ternary
    or p_value ~ '(''\s*\+|\+\s*'')'                 -- string concatenation
    or p_value ~ '^\s*''.*''\s*$'                    -- a bare Dart literal
    or p_value ~ ';\s*$'                             -- a trailing semicolon
  end;
$fn$;

-- Re-validate over every row with the widened rule. This is the assertion that
-- the measurement above was real: if any of the 6,115 rows matched, this fails
-- the migration rather than shipping a guard nobody can satisfy.
alter table public.ui_copy drop constraint if exists ui_copy_no_dart_source;
alter table public.ui_copy add constraint ui_copy_no_dart_source
  check (not public.ui_copy_is_source_code(value #>> '{}'));

-- ── 2. finding 382: the guard read presence, not state ──────────────────
-- `exists (select 1 from pg_trigger …)` is still true after
-- ALTER TABLE ui_copy DISABLE TRIGGER ui_copy_guard_trg (tgenabled='D'), and
-- the CHECK could be re-added NOT VALID and still be found. Both are one
-- statement away from a green guard over an unguarded table.
--
-- ── 3. finding 384: RLS restated, not amended ───────────────────────────
-- The RLS for the two new tables was shipped by editing a migration file that
-- had already been applied, so the live database has it and a fresh apply of
-- that file would not. Restating it here — idempotently — is what makes the
-- migration history true.
alter table public.ui_copy_param_drift  enable row level security;
alter table public.ui_copy_source_exempt enable row level security;
revoke all on table public.ui_copy_param_drift  from anon, authenticated;
revoke all on table public.ui_copy_source_exempt from anon, authenticated;
revoke all on function public.ui_copy_param_drift_report(jsonb)
  from public, anon, authenticated;
grant execute on function public.ui_copy_param_drift_report(jsonb) to service_role;

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

  -- ROUND 5: a constraint that exists but was re-added NOT VALID guards only
  -- the rows written after it.
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.ui_copy'::regclass
                    and conname = 'ui_copy_no_dart_source'
                    and convalidated) then
    raise exception 'C686: the ui_copy_no_dart_source CHECK is missing or was re-added NOT VALID';
  end if;

  -- ROUND 5: DISABLE TRIGGER leaves the row in pg_trigger with tgenabled='D',
  -- so presence was never the question.
  if not exists (select 1 from pg_trigger
                  where tgrelid = 'public.ui_copy'::regclass
                    and tgname = 'ui_copy_guard_trg' and not tgisinternal
                    and tgenabled <> 'D') then
    raise exception 'C686: the ui_copy_guard_trg source guard has been dropped or disabled';
  end if;

  -- ROUND 3: the guard's own RPC must stay service_role-only. It is SECURITY
  -- DEFINER over a table under RLS, so an EXECUTE grant to authenticated is a
  -- way for any signed-in account to red the guard for the whole queue.
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'ui_copy_param_drift_report'
                and (has_function_privilege('authenticated', p.oid, 'EXECUTE')
                  or has_function_privilege('anon', p.oid, 'EXECUTE')
                  or has_function_privilege('public', p.oid, 'EXECUTE'))) then
    raise exception 'C686: ui_copy_param_drift_report is callable by anon/authenticated';
  end if;

  -- ROUND 5: the RPC's in-body second layer must not go back to reading
  -- current_user, which is ALWAYS 'postgres' inside a SECURITY DEFINER function
  -- owned by postgres and so could never fire.
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'ui_copy_param_drift_report'
                and p.prosrc !~ 'request\.jwt\.claim') then
    raise exception 'C686: ui_copy_param_drift_report no longer checks the JWT role claim';
  end if;

  raise exception 'RG_ROLLBACK';
end $x$;
$body$
where name = 'c686_ui_copy_is_copy';

-- ═══════════════════════════════════════════════════════════════════════════
-- 4. THE FIVE JOURNEYS. Each one is a QA blocker filed against #686, written
--    as the CLASS it belongs to rather than as the single row that was
--    photographed.
-- ═══════════════════════════════════════════════════════════════════════════

-- qa-686-365 — the header Om reported, and the reason it broke TWICE.
-- First it rendered Dart source; then the copy was fixed ahead of the Dart and
-- it rendered no customer name at all, because cf() was still being handed
-- {a}/{b} for a template that had moved to {name}. The class is not "this row
-- is right" — it is "every template's slots are the ones its call site fills",
-- which is what ui_copy_param_drift records.
create or replace function public._journey_c686_header_slots()
returns jsonb language plpgsql stable as $fn$
declare v_a1 boolean; v_a2 boolean; v_a3 boolean; v_a4 boolean; v_drift int;
        v_plain text; v_ph text;
begin
  select value #>> '{}' into v_plain from public.ui_copy where key = 'admin_customer.ordered_by';
  select value #>> '{}' into v_ph    from public.ui_copy where key = 'admin_customer.ordered_by_with_pharmacy';
  -- the header is a sentence with a NAMED slot, not source and not a bare label
  v_a1 := v_plain = 'Ordered by: {name}';
  v_a2 := v_ph is not null and v_ph like '%{name}%' and v_ph like '%{pharmacy}%';
  -- neither row may be Dart source under any of the three rules
  v_a3 := not (public.ui_copy_is_source_code(v_plain) or public.ui_copy_brace_is_source(v_plain)
            or public.ui_copy_is_source_code(v_ph)    or public.ui_copy_brace_is_source(v_ph));
  -- and the silent half: no template anywhere disagrees with its call site
  select count(*) into v_drift from public.ui_copy_param_drift;
  v_a4 := v_drift = 0;
  return jsonb_build_object(
    'status', case when v_a1 and v_a2 and v_a3 and v_a4 then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'ordered_by=' || coalesce(v_plain,'<null>') ||
      ' | with_pharmacy=' || coalesce(v_ph,'<null>') ||
      ' | neither is source=' || coalesce(v_a3,false)::text ||
      ' | call-site/template drift rows=' || v_drift::text));
end $fn$;

-- qa-686-366 — "10 more casualties left unfixed". The class is the Aug-9 sweep
-- itself: it wrote Dart expressions into copy across the whole table, so the
-- assertion is over the WHOLE table, not over a list of keys. The named
-- casualties are then pinned individually, because a rule can be satisfied by
-- a row that is clean and still wrong ('drug_license' as the GST label passed
-- every shape rule ever written).
create or replace function public._journey_c686_sweep_complete()
returns jsonb language plpgsql stable as $fn$
declare v_n int; v_bad text; v_a2 boolean; v_named int;
begin
  select count(*), string_agg(key, ', ' order by key) into v_n, v_bad
    from public.ui_copy
   where public.ui_copy_is_source_code(value #>> '{}')
      or ((public.ui_copy_brace_is_source(value #>> '{}')
           or public.ui_copy_bare_expression(value #>> '{}'))
          and not exists (select 1 from public.ui_copy_source_exempt e where e.key = ui_copy.key));
  -- the nine rows QA named, each pinned to the sentence it should have been
  select count(*) into v_named from (values
    ('admin_company.gst_prefix',                    'GST: {v}'),
    ('admin_company.dl_prefix',                     'DL: {v}'),
    ('unmapped_companies.toast_mapped',             '{raw} → {name}'),
    ('sup_pay.toast_payment_recorded',              '{kind} payment recorded ✓'),
    ('profile.viewas_confirm_body',                 'Any changes (cart, orders, profile) will be SAVED to {name}.'),
    ('cust_pay.qr_image_title',                     'Scan to pay'),
    ('cust_pay.qr_image_upi_line',                  'UPI ID: {vpa}')
  ) as w(k, expected)
  join public.ui_copy u on u.key = w.k and u.value #>> '{}' = w.expected;
  -- the four whose exact wording is prose, asserted on the property that BROKE
  -- rather than on the wording: a dropped slot, a sentence truncated mid-word,
  -- a fragment that never started as one, and a literal \u escape. Note
  -- err_new_column_name_empty legitimately ENDS in }" — the slot sits inside
  -- quotes — so it is pinned on being a capitalised sentence that still owns
  -- its {column} slot, not on its tail.
  select (
       (select value #>> '{}' from public.ui_copy where key='wa_campaigns.cancel_body') like '%{name}%'
   and (select value #>> '{}' from public.ui_copy where key='notifications.allowlist_note') ~ '\.$'
   and (select value #>> '{}' from public.ui_copy where key='admin_add_medicine.err_new_column_name_empty') ~ '^[A-Z].*\{column\}'
   and (select value #>> '{}' from public.ui_copy where key='cash_payment.btn_collect_cash') !~ '\\u'
  ) into v_a2;
  return jsonb_build_object(
    'status', case when v_n = 0 and v_named = 7 and coalesce(v_a2,false) then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'rows still holding Dart source=' || v_n::text ||
      case when v_n > 0 then ' (' || left(coalesce(v_bad,''), 300) || ')' else '' end ||
      ' | named casualties repaired=' || v_named::text || '/7' ||
      ' | truncated/escaped prose repaired=' || coalesce(v_a2,false)::text));
end $fn$;

-- qa-686-367 — "the guard misses 14 of 16 broken shapes". A detector is only
-- worth what it REJECTS, so this journey runs the real functions over a
-- battery of specimens: every shape QA got past a previous round must be
-- refused, and every legitimate string it named must still be storable. It is
-- the regression test for the guard itself, and it fails the moment someone
-- loosens a rule to make an inconvenient row save.
create or replace function public._journey_c686_detector_battery()
returns jsonb language plpgsql stable as $fn$
declare v_missed text[] := '{}'; v_false text[] := '{}'; v text;
  c_bad constant text[] := array[
    -- Om's own bug, and the same shape one dollar sign lighter
    'Ordered by: ${row.pharmacy.isNotEmpty ?',
    'Ordered by: {row.pharmacy.isNotEmpty ? row.pharmacy : row.name}',
    -- round 2's escapes
    '] != null ? ', '{{ b[0] ; return x }}', '{{items.length}}', '{ if (x) {ok} }',
    '{a: {b}}', 'items.first.name', 'items.first.name ', ' items.first.name',
    -- round 3's escapes
    'UPI ID: $vpa', 'total.length', 'x ?? y', 'value != null',
    -- round 4/5's escapes (R3-4)
    'Theme.of(context).textTheme.bodyMedium', 'EdgeInsets.all(16)',
    'const SizedBox(height: 8)', 'TextStyle(fontWeight: FontWeight.w600)',
    'DateFormat(''dd MMM yyyy'').format(date)', 'order.total.abs()',
    '(x) => x.name', 'count > 1 ? ''items'' : ''item''', '''Total: ''',
    '''Qty: '' + qty', '\u{1F4B5}  Collect Cash'];
  c_good constant text[] := array[
    'Ordered by: {name}', 'Ordered by: {name} · {pharmacy}', '₹{amount}',
    'Heartbeat FAILED at {{stage}}', 'Doctor''s prescription', 'Save $5 today',
    'US$ 20', 'Visit https://medibo.in for help', 'https://company.com (optional)',
    'Loading...', 'Cancel this order?', 'Your order is on the way.', ', ',
    'Scan to pay', 'UPI ID: {vpa}', 'GST: {v}', 'new_column_name',
    'Proforma — not a tax invoice. Rates and GST are final; batch may change.'];
begin
  foreach v in array c_bad loop
    if not (public.ui_copy_is_source_code(v) or public.ui_copy_brace_is_source(v)
            or public.ui_copy_bare_expression(v)) then
      v_missed := v_missed || v;
    end if;
  end loop;
  foreach v in array c_good loop
    if public.ui_copy_is_source_code(v) or public.ui_copy_brace_is_source(v)
       or public.ui_copy_bare_expression(v) then
      v_false := v_false || v;
    end if;
  end loop;
  return jsonb_build_object(
    'status', case when cardinality(v_missed) = 0 and cardinality(v_false) = 0
                   then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'known-bad shapes refused=' || (cardinality(c_bad) - cardinality(v_missed))::text
        || '/' || cardinality(c_bad)::text ||
      case when cardinality(v_missed) > 0 then ' | ACCEPTED: ' || array_to_string(v_missed, ' ¦ ') else '' end ||
      ' | legitimate copy still storable=' || (cardinality(c_good) - cardinality(v_false))::text
        || '/' || cardinality(c_good)::text ||
      case when cardinality(v_false) > 0 then ' | FALSE POSITIVE: ' || array_to_string(v_false, ' ¦ ') else '' end));
end $fn$;

-- qa-686-378 — 'UPI ID: $vpa' painted onto the QR image a paying customer
-- downloads. The class is the BARE $identifier: round 2's guard looked for
-- '${' and a customer-facing row walked straight through it. Asserted as a
-- rule, on the whole table, and on the two strings that must fall on opposite
-- sides of it ('$vpa' is source, '$5' is money).
create or replace function public._journey_c686_bare_dollar()
returns jsonb language plpgsql stable as $fn$
declare v_n int; v_bad text; v_title text; v_upi text; v_a4 boolean;
begin
  select count(*), string_agg(key || ' = ' || left(value #>> '{}', 50), ' | ' order by key)
    into v_n, v_bad
    from public.ui_copy where (value #>> '{}') ~ '\$[A-Za-z_]';
  select value #>> '{}' into v_title from public.ui_copy where key = 'cust_pay.qr_image_title';
  select value #>> '{}' into v_upi   from public.ui_copy where key = 'cust_pay.qr_image_upi_line';
  v_a4 := public.ui_copy_is_source_code('UPI ID: $vpa')
      and not public.ui_copy_is_source_code('Save $5 today')
      and not public.ui_copy_is_source_code('US$ 20');
  return jsonb_build_object(
    'status', case when v_n = 0 and v_title !~ '\$[A-Za-z_]' and v_upi = 'UPI ID: {vpa}'
                    and coalesce(v_a4,false) then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'rows with a bare $identifier=' || v_n::text ||
      case when v_n > 0 then ' (' || left(coalesce(v_bad,''), 200) || ')' else '' end ||
      ' | qr_image_title=' || coalesce(v_title,'<null>') ||
      ' | qr_image_upi_line=' || coalesce(v_upi,'<null>') ||
      ' | rule separates $vpa from $5/US$ 20=' || coalesce(v_a4,false)::text));
end $fn$;

-- qa-686-379 — the guard's own RPC was SECURITY DEFINER with EXECUTE for every
-- logged-in account, over a table whose contents turn rg_check red — so any
-- signed-in user could stop the WHOLE dev queue completing, or wipe real drift
-- to hide it. Round 4 then found the in-body second layer was dead code:
-- inside a SECURITY DEFINER function owned by postgres, current_user is always
-- 'postgres', so that conjunct could never be true. Both halves are asserted:
-- the grants are closed, AND the body reads the signal that actually
-- identifies a PostgREST caller.
create or replace function public._journey_c686_drift_rpc_fenced()
returns jsonb language plpgsql stable as $fn$
declare v_oid oid; v_src text; v_a1 boolean; v_a2 boolean; v_a3 boolean;
        v_a4 boolean; v_acl text;
begin
  select p.oid, p.prosrc into v_oid, v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'ui_copy_param_drift_report';
  if v_oid is null then
    return jsonb_build_object('status','failed','evidence',
      jsonb_build_object('db_proof','ui_copy_param_drift_report does not exist'));
  end if;
  v_a1 := not (has_function_privilege('anon', v_oid, 'EXECUTE')
            or has_function_privilege('authenticated', v_oid, 'EXECUTE')
            or has_function_privilege('public', v_oid, 'EXECUTE'));
  v_a2 := has_function_privilege('service_role', v_oid, 'EXECUTE');
  -- the body keys off the JWT role claim, and no longer off current_user,
  -- which is 'postgres' inside this function whatever the caller is
  v_a3 := v_src ~ 'request\.jwt\.claim' and v_src !~ 'current_user';
  -- the table it writes is not readable or writable by a logged-in account
  -- either, so RLS is not the only thing standing between them
  v_a4 := not (has_table_privilege('anon','public.ui_copy_param_drift','SELECT')
            or has_table_privilege('authenticated','public.ui_copy_param_drift','SELECT')
            or has_table_privilege('authenticated','public.ui_copy_param_drift','INSERT')
            or has_table_privilege('authenticated','public.ui_copy_param_drift','DELETE'));
  select coalesce(array_to_string(p.proacl::text[], ' '), '<default>') into v_acl
    from pg_proc p where p.oid = v_oid;
  return jsonb_build_object(
    'status', case when v_a1 and v_a2 and v_a3 and v_a4 then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'closed to anon/authenticated/public=' || coalesce(v_a1,false)::text ||
      ' | service_role can call=' || coalesce(v_a2,false)::text ||
      ' | body reads the JWT role claim, not current_user=' || coalesce(v_a3,false)::text ||
      ' | drift table closed to logged-in accounts=' || coalesce(v_a4,false)::text ||
      ' | acl=' || v_acl));
end $fn$;

-- ── 5. the probe learns the five names ──────────────────────────────────
-- dev_journey_probe's default branch counts externally-filed passes, which is
-- why these five reported 'skipped — browser runner needs 2 more run(s)'
-- forever: no browser can prove a statement about a table. Dispatch them the
-- way every other api journey is dispatched.
CREATE OR REPLACE FUNCTION public.dev_journey_probe(p_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_ok boolean; v_ev jsonb; v_v text; v_row record; v_jid bigint; v_pass_count int;
        v_sql text; v_chk jsonb; v_base_hash text; v_bl jsonb; v_err text;
        v_a1 boolean; v_a2 boolean; v_a3 boolean; v_a4 boolean; v_a5 boolean; v_a6 boolean;
        c_target constant text := 'my_orders_chandra_slice';
begin
  perform public._dev_guard();

  -- CHANGE #686 (round 5) — the five QA blockers filed against this command,
  -- each retired as the CLASS it belongs to rather than as the row that was
  -- photographed. They arrived as stubs reading "TODO implement before
  -- completing #686" and so fell through to the external-proof branch below,
  -- which reported 'skipped — browser runner needs 2 more run(s)' forever:
  -- no browser can prove a statement about a table.
  if p_name = 'qa-686-365' then return public._journey_c686_header_slots();     end if;
  if p_name = 'qa-686-366' then return public._journey_c686_sweep_complete();   end if;
  if p_name = 'qa-686-367' then return public._journey_c686_detector_battery(); end if;
  if p_name = 'qa-686-378' then return public._journey_c686_bare_dollar();      end if;
  if p_name = 'qa-686-379' then return public._journey_c686_drift_rpc_fenced(); end if;


  -- CMD #418 — a model provider's raw error reaching a pharmacy's till,
  -- retired as a class (see _journey_c418_provider_error).
  if p_name = 'qa-418-233' then return public._journey_c418_provider_error(); end if;


  -- CHANGE #436 — the default PUBLIC EXECUTE grant, closed as a class.
  if p_name = 'bug-436' then return public._journey_bug436(); end if;
  -- CHANGE #683 — the same default-PUBLIC-grant class on the zone and
  -- storefront maintenance surface: unguarded refresh/rebuild jobs are
  -- tokenless compute on a 1 GB instance, and zone_supplier_names was
  -- handing the supplier roster to the bundled anon key.
  if p_name = 'bug-683' then return public._journey_bug683(); end if;
  -- CMD #467 — the same default-PUBLIC-grant class, on the partner audit
  -- surface this command added. Writing it found the quieter half: a grant is
  -- not a guard, and admin_partner_audit_preview() had EXECUTE for every
  -- authenticated login with no role check in its body.
  if p_name = 'qa-467-323' then return public._journey_c467_partner_audit_fence(); end if;
  -- CMD #633 — a raw copy template rendered at a reader, retired as a
  -- class: cf() reports every unfilled slot on the render log.
  if p_name = 'bug-633' then return public._journey_bug633(); end if;
  -- CMD #450 — the three QA blockers this command found, each retired as a
  -- class rather than as one fix: a write action naming an event key nobody
  -- registered (both of #450's actions shipped that way), and a save-time
  -- guard that a TRIGGER walked around.
  if p_name in ('qa-450-250','qa-450-251') then
    return public._journey_c450_live_event_keys();
  end if;
  if p_name = 'qa-450-252' then return public._journey_c450_autoenable_gated(); end if;
  -- CHANGE #408 — the three QA blockers this command found, each retired as a
  -- class rather than as one screenshot: the staff binding that handed a
  -- pharmacy away, the edit window that stayed open after a supplier was
  -- asked, and the basket that was totalled on MRP.
  if p_name = 'qa-408-216' then return public._journey_c408_binding(); end if;
  if p_name = 'qa-408-217' then return public._journey_c408_window();  end if;
  if p_name = 'qa-408-218' then return public._journey_c408_pricing(); end if;
  -- CHANGE #414 — one pharmacy reading another's shelf, retired as a class:
  -- the sweep also fails on the NEXT shop-scoped function written without the
  -- fence, not just on the one that leaked.
  if p_name = 'qa-414-227' then return public._journey_c414_shop_fence(); end if;
  -- CHANGE #424 — the same class in the inference engine, caught by qa-414-227
  -- on #424 itself: an engine internal that takes a shop id must never be
  -- client-reachable, and fencing it must not fence the owner out.
  if p_name = 'qa-424-237' then return public._journey_c424_shop_fence(); end if;
  -- CHANGE #319 — QA blockers 156/157 (version.json served HTML).
  if p_name in ('qa-319-156','qa-319-157') then
    return public._journey_qa319_version();
  end if;

  -- CHANGE #240 — inquiry->PO date integrity (see _journey_bug240).
  if p_name = 'bug-240' then return public._journey_bug240(); end if;

  -- CHANGE #197 — the confirm re-read may only CONFIRM drift, never clear it.
  -- Regression guard for the false-negative: a payload target that DIFFERS on
  -- read 1 and then ERRORS on the confirm read used to vanish from both
  -- diffs.payload.changed and collection_errors, so rg_check returned ok:true
  -- while a real change sat unreported.
  if p_name = 'bug-197' then
    v_err := null;
    select position('confirm re-read failed' in p.prosrc) > 0 into v_a1
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public' and p.proname='rg_check';
    begin
      create table if not exists public._j197_ctr(n int);
      delete from public._j197_ctr where true; insert into public._j197_ctr values (0);
      execute 'create or replace function public._j197_tick() returns int language plpgsql as '
           || '$b$ declare v int; begin update public._j197_ctr set n = n + 1 where true returning n into v; '
           || 'if v >= 2 then raise exception ''j197 confirm read''; end if; return 42; end $b$';
      delete from rg_payload_targets where name = '_j197_probe';
      delete from rg_baseline where kind = 'payload' and name = '_j197_probe';
      insert into rg_payload_targets(name, sql, enabled)
        values ('_j197_probe', 'select jsonb_build_object(''v'', public._j197_tick())', true);
      insert into rg_baseline(kind, name, hash, content)
        values ('payload','_j197_probe','deadbeefdeadbeefdeadbeefdeadbeef','{"v":0}'::jsonb);

      v_chk := public.rg_check(false, true);
      select exists (select 1 from jsonb_array_elements_text(
                       coalesce(v_chk->'diffs'->'payload'->'changed','[]'::jsonb)) x
                      where x = '_j197_probe') into v_a2;
      select exists (select 1 from jsonb_array_elements(
                       coalesce(v_chk->'collection_errors','[]'::jsonb)) e
                      where e->>'name' = '_j197_probe') into v_a3;
    exception when others then
      v_a2 := false; v_a3 := false; v_err := sqlerrm;
    end;

    begin
      delete from rg_payload_targets where name = '_j197_probe';
      delete from rg_baseline where kind = 'payload' and name = '_j197_probe';
      execute 'drop function if exists public._j197_tick()';
      execute 'drop table if exists public._j197_ctr';
    exception when others then null;
    end;

    v_ok := coalesce(v_a1,false) and coalesce(v_a2,false) and coalesce(v_a3,false);
    return jsonb_build_object(
      'status', case when v_ok then 'passed' else 'failed' end,
      'evidence', jsonb_build_object(
        'db_proof',
          'rg_check carries the unconfirmable-drift rule=' || coalesce(v_a1::text,'null')
          || ' | drift KEPT in changed when the confirm read errors=' || coalesce(v_a2::text,'null')
          || ' | reason surfaced in collection_errors=' || coalesce(v_a3::text,'null'),
        'probe_cleaned_up', not exists (select 1 from rg_payload_targets where name = '_j197_probe'),
        'error', v_err));
  end if;

  -- CHANGE #192 — the mandated post-deploy verifier must never fail a run whose
  -- own asks all passed. Asserted from verify_run_log, which render_verify.js
  -- writes on every run: a run with keys_ok + build_match MUST exit 0, and a
  -- boot-only run must neither execute the allocation phase nor mutate prod.
  if p_name = 'bug-192' then
    select count(*) into v_pass_count from verify_run_log where at > now() - interval '7 days';
    if v_pass_count = 0 then
      return jsonb_build_object('status','skipped','evidence',
        jsonb_build_object('reason','no render_verify run recorded in the last 7 days'));
    end if;

    select count(*) = 0 into v_ok
    from verify_run_log l
    where l.at > now() - interval '7 days'
      and (
        (l.keys_ok and l.build_match and l.exit_code <> 0
           and coalesce(array_length(l.phases_failed,1),0) = 0)
        or (coalesce(array_length(l.requested_phases,1),0) > 0
            and exists (select 1 from unnest(l.phases_run) p
                        where not (p = any(l.requested_phases)) and p <> 'boot'))
        or (l.mutated and coalesce(array_length(l.requested_phases,1),0) > 0
            and not (l.requested_phases && array['allocation','receiving','voice','arrivals']))
      );

    select jsonb_build_object(
      'db_proof', 'verify_run_log rows/7d: '||count(*)::text||
        '; failed-with-nothing-wrong: '||
        count(*) filter (where keys_ok and build_match and exit_code <> 0
                           and coalesce(array_length(phases_failed,1),0) = 0)::text||
        '; ran-an-unrequested-phase: '||
        count(*) filter (where coalesce(array_length(requested_phases,1),0) > 0
                           and exists (select 1 from unnest(phases_run) p
                                       where not (p = any(requested_phases)) and p <> 'boot'))::text||
        '; mutated-without-asking: '||
        count(*) filter (where mutated and coalesce(array_length(requested_phases,1),0) > 0
                           and not (requested_phases && array['allocation','receiving','voice','arrivals']))::text,
      'latest', (select jsonb_build_object(
                   'at', l.at::text, 'commit', l.commit_hash, 'exit_code', l.exit_code,
                   'keys', to_jsonb(l.requested_keys),
                   'asked_for', to_jsonb(l.requested_phases),
                   'ran', to_jsonb(l.phases_run),
                   'failed', to_jsonb(l.phases_failed),
                   'mutated', l.mutated)
                 from verify_run_log l order by l.at desc limit 1))
      into v_ev
    from verify_run_log where at > now() - interval '7 days';

    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end, 'evidence', v_ev);
  end if;
  if p_name = 'backup-lands' then
    select bool_and(ok) and count(*) filter (where kind='db') >= 1
           and count(*) filter (where kind='repo') >= 1 into v_ok
    from backup_log where at > now() - interval '26 hours'
      and (size_mb)::numeric > 1 and ok;
    select jsonb_build_object(
      'db_proof', 'backup_log rows in last 26h: '||coalesce(count(*),0)::text,
      'latest', max(at)::text) into v_ev
    from backup_log where at > now() - interval '26 hours' and ok;
    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end, 'evidence', v_ev);

  elsif p_name = 'eta-honest' then
    select count(*) = 0 into v_ok
    from dev_commands
    where status='building' and eta_left_s is not null and eta_total_s is not null
      and eta_left_s > eta_total_s and coalesce(eta_note,'') = '';
    select jsonb_build_object(
      'db_proof', 'building rows: '||count(*) filter (where status='building')::text||
                  '; inflated-without-note: '||
                  count(*) filter (where status='building' and eta_left_s>eta_total_s and coalesce(eta_note,'')='')::text
    ) into v_ev from dev_commands;
    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end, 'evidence', v_ev);

  elsif p_name = 'add-media-survives' then
    select m.* into v_row from dev_command_messages m
    where jsonb_array_length(coalesce(m.images,'[]'::jsonb)) > 0
    order by m.id desc limit 1;
    if not found then
      return jsonb_build_object('status','skipped','evidence',
        jsonb_build_object('reason','no message with images yet'));
    end if;
    select bool_and(coalesce(trim(x),'') <> '') into v_ok
    from jsonb_array_elements_text(v_row.images) x;
    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end,
      'evidence', jsonb_build_object('db_proof','message #'||v_row.id||' images non-empty='||v_ok));

  elsif p_name = 'reply-media-live' then
    select m.* into v_row from dev_command_messages m
    where coalesce(m.sender,'') = 'om'
      and jsonb_array_length(coalesce(m.images,'[]'::jsonb)) > 0
    order by m.id desc limit 1;
    if not found then
      return jsonb_build_object('status','skipped','evidence',
        jsonb_build_object('reason','no reply-with-photo yet'));
    end if;
    -- c290-strengthen: presence is not content. bool_and over the paths.
    select bool_and(coalesce(trim(x),'') <> '') into v_ok
    from jsonb_array_elements_text(v_row.images) x;
    return jsonb_build_object('status', case when coalesce(v_ok,false) then 'passed' else 'failed' end,
      'evidence', jsonb_build_object('db_proof','reply message #'||v_row.id||' carries '||
        jsonb_array_length(v_row.images)::text||' image(s); every path non-empty='||
        coalesce(v_ok,false)::text));

  elsif p_name = 'android-apk-produces-file' then
    select count(*) > 0 into v_ok from dev_commands
    where android_status='built' and coalesce(android_artifact_url,'') <> '';
    if not v_ok then
      return jsonb_build_object('status','skipped','evidence',
        jsonb_build_object('reason','no built android artifact on record yet'));
    end if;
    return jsonb_build_object('status','passed','evidence',
      jsonb_build_object('db_proof','built android artifacts: '||
        (select count(*) from dev_commands where android_status='built')::text));

  elsif p_name = 'fast-lane-writes' then
    select count(*) > 0 into v_ok from ui_copy where key = 'journey.test' and value is not null;
    if not v_ok then
      return jsonb_build_object('status','skipped','evidence',
        jsonb_build_object('reason','ui_copy journey.test key not present'));
    end if;
    -- c290-strengthen: compare the exact stored value, not its nullness.
    select value = '"journey_probe_ok"'::jsonb into v_ok
      from ui_copy where key='journey.test';
    return jsonb_build_object('status', case when coalesce(v_ok,false) then 'passed' else 'failed' end,
      'evidence', jsonb_build_object('db_proof',
        'ui_copy journey.test='||(select value::text from ui_copy where key='journey.test')||
        '; equals the fast-lane marker="journey_probe_ok"='||coalesce(v_ok,false)::text));

  elsif p_name = 'gcp-taps-enqueue' then
    select count(*) > 0 into v_ok from dev_commands where kind='gcp';
    if not v_ok then
      return jsonb_build_object('status','skipped','evidence',
        jsonb_build_object('reason','no gcp-kind command on record yet'));
    end if;
    return jsonb_build_object('status','passed','evidence',
      jsonb_build_object('db_proof',
        'gcp commands on record: '||(select count(*) from dev_commands where kind='gcp')::text));

  elsif p_name = 'pool-settings-save' then
    select (select value from dev_runner_config where key='worker_pool') is not null into v_ok;
    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end,
      'evidence', jsonb_build_object(
        'db_proof', 'worker_pool config readable; sec_pin_verify(null)='||
          (sec_pin_verify(null))::text));

  elsif p_name = 'rollback-creates-command' then
    select count(*) > 0 into v_ok
    from dev_commands where title like 'Rollback #%' and urgent=true;
    if not v_ok then
      return jsonb_build_object('status','skipped','evidence',
        jsonb_build_object('reason','no Rollback command on record yet'));
    end if;
    return jsonb_build_object('status','passed','evidence',
      jsonb_build_object('db_proof',
        'urgent Rollback commands on record: '||
        (select count(*) from dev_commands where title like 'Rollback #%' and urgent=true)::text));

  elsif p_name = 'bug-191' then
    -- CHANGE #191. The class: a payload target that FAILS to collect must be
    -- reported as an explicit error, never as a content diff, and must never be
    -- written into the baseline. Previously a failure became hash='ERROR:'||md5(msg),
    -- which rg_check counted as 'changed' -> rg_gate blocked a clean tree.
    --
    -- Structural guards first (cheap, no mutation).
    select p.proconfig::text like '%statement_timeout%' into v_a1
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public' and p.proname='rg_collect_payloads';
    -- 57014 is not matched by OTHERS; it must be named or it escapes the guard.
    select p.prosrc like '%query_canceled%' into v_a2
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public' and p.proname='rg_collect_payloads';
    select not exists (select 1 from rg_baseline where kind='payload' and hash='ERROR') into v_a3;

    select b.hash into v_base_hash from rg_baseline b where b.kind='payload' and b.name=c_target;
    select pt.sql into v_sql from rg_payload_targets pt where pt.name=c_target;
    if v_sql is null or v_base_hash is null then
      return jsonb_build_object('status','skipped','evidence',
        jsonb_build_object('reason','probe target '||c_target||' is not baselined'));
    end if;

    -- Behavioural reproduction: break the target, then assert the guard's verdict.
    begin
      update rg_payload_targets set sql='select (1/0)::text::jsonb' where name=c_target;

      v_chk := rg_check(false, true);

      -- (a) the failure is surfaced as a collection error
      v_a4 := exists (select 1 from jsonb_array_elements(coalesce(v_chk->'collection_errors','[]'::jsonb)) e
                       where e->>'name' = c_target);
      -- (b) and is NOT counted as drift
      v_a5 := not exists (select 1 from jsonb_array_elements_text(
                            coalesce(v_chk->'diffs'->'payload'->'changed','[]'::jsonb)) t(nm)
                          where t.nm = c_target);

      -- (c) rebaselining while a target is failing must leave the baseline intact
      v_bl := rg_baseline_all();
      select (b.hash = v_base_hash) into v_a6
        from rg_baseline b where b.kind='payload' and b.name=c_target;

      update rg_payload_targets set sql=v_sql where name=c_target;
    exception when others then
      update rg_payload_targets set sql=v_sql where name=c_target;
      v_err := sqlerrm;
      return jsonb_build_object('status','failed','evidence',
        jsonb_build_object('db_proof','probe raised, target SQL restored: '||v_err));
    end;

    v_ok := coalesce(v_a1,false) and coalesce(v_a2,false) and coalesce(v_a3,false)
        and coalesce(v_a4,false) and coalesce(v_a5,false) and coalesce(v_a6,false);

    return jsonb_build_object(
      'status', case when v_ok then 'passed' else 'failed' end,
      'evidence', jsonb_build_object(
        'db_proof',
          'target='||c_target||
          ' | rg_collect_payloads has statement_timeout='||coalesce(v_a1,false)::text||
          ' | names query_canceled='||coalesce(v_a2,false)::text||
          ' | no ERROR hash in baseline='||coalesce(v_a3,false)::text||
          ' | broken target reported as collection_error='||coalesce(v_a4,false)::text||
          ' | broken target NOT counted as diff='||coalesce(v_a5,false)::text||
          ' | rg_baseline_all left baseline intact='||coalesce(v_a6,false)::text,
        'diffs_while_broken', coalesce(v_chk->'summary','{}'::jsonb),
        'baseline_run', coalesce(v_bl->'baselined'->'payload','null'::jsonb),
        'target_sql_restored', true));

  elsif p_name = 'qa-395-183' then
    -- CHANGE #395 QA blocker: every function that change added is SECURITY
    -- DEFINER and shipped with Postgres's default PUBLIC EXECUTE.
    -- _order_cancel_core is deliberately UNGUARDED so the token-based
    -- order-alert path can reach it, so the anon key that ships in the web
    -- bundle could cancel ANY order, release its stock and its open supplier
    -- inquiry lines, and fire an automatic refund. Same shape as
    -- feature_gaps #25, CHANGE #353 and audit_write() in #422.
    --
    -- Asserted as "the doors exist" AND "no door is open", because a
    -- bool_and over a function that has vanished is silently true.
    select count(*) = 22 into v_a1
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public'
       and p.proname in ('_order_cancel_core','_returns_guard','_return_line_money',
                         '_return_returnable_qty','_order_collected','_order_refunded',
                         '_order_paid_net','_order_rzp_payment_id','_rzp_refund_apply',
                         '_order_credit_notes','gst_ledger_build_credit_notes',
                         'refund_prepare','refund_store','returns_orders_list',
                         'order_returns_panel','order_return_add','order_return_approve',
                         'order_return_reject','refund_quote','refund_request',
                         'refund_mark_manual','refund_cancel');
    -- anon is the key in the bundle. Not one of these may be reachable by it.
    select count(*) = 0 into v_a2
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public'
       and p.proname in ('_order_cancel_core','_returns_guard','_return_line_money',
                         '_return_returnable_qty','_order_collected','_order_refunded',
                         '_order_paid_net','_order_rzp_payment_id','_rzp_refund_apply',
                         '_order_credit_notes','gst_ledger_build_credit_notes',
                         'refund_prepare','refund_store','returns_orders_list',
                         'order_returns_panel','order_return_add','order_return_approve',
                         'order_return_reject','refund_quote','refund_request',
                         'refund_mark_manual','refund_cancel')
       and has_function_privilege('anon', p.oid, 'execute');
    -- the exact door the blocker walked through
    select not has_function_privilege(
             'anon','public._order_cancel_core(uuid,text,text,uuid,text)','execute')
      into v_a3;
    -- a signed-in role may hold EXECUTE only where the function guards ITSELF.
    select count(*) = 0 into v_a4
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public'
       and p.proname in ('_order_cancel_core','_return_line_money','_return_returnable_qty',
                         '_order_collected','_order_refunded','_order_paid_net',
                         '_order_rzp_payment_id','_rzp_refund_apply',
                         'gst_ledger_build_credit_notes','refund_prepare','refund_store')
       and has_function_privilege('authenticated', p.oid, 'execute');
    -- and the ledgers themselves stay closed to the bundle key.
    select count(*) = 0 into v_a5
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname='public'
       and c.relname in ('order_returns','refunds','order_cancellations')
       and (has_table_privilege('anon', c.oid, 'insert')
         or has_table_privilege('anon', c.oid, 'update')
         or has_table_privilege('anon', c.oid, 'delete'));
    v_ok := coalesce(v_a1,false) and coalesce(v_a2,false) and coalesce(v_a3,false)
        and coalesce(v_a4,false) and coalesce(v_a5,false);
    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end,
      'evidence', jsonb_build_object('db_proof',
        'all 22 returns/refund RPCs present='||coalesce(v_a1,false)::text||
        ' | none EXECUTE-able by anon='||coalesce(v_a2,false)::text||
        ' | _order_cancel_core denied to anon='||coalesce(v_a3,false)::text||
        ' | no unguarded helper reachable by authenticated='||coalesce(v_a4,false)::text||
        ' | no returns ledger writable by anon='||coalesce(v_a5,false)::text));

  elsif p_name = 'qa-273-47' then
    -- c290-strengthen. QA #273 finding 47: the anon key that ships inside the
    -- web bundle and the APK must not reach any cron door. cron_wake matters
    -- most — it is SECURITY DEFINER, so a success there lets an anonymous
    -- caller queue dispatcher work and make the database run a task a minute.
    -- Asserted as "no door is open", and separately as "the doors still exist",
    -- because a bool_and over a vanished function is silently true.
    select count(*) = 6 into v_a1
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public'
       and p.proname in ('cron_wake','cron_dispatch','cron_run','cron_add',
                         'cron_guard_sweep','cron_health');
    -- c290-probe-fix: anon is the key that ships in the bundle, and it is the
    -- key this journey is about. A signed-in role may hold EXECUTE only where
    -- the function guards itself — cron_health does, and the super-admin Cron
    -- Health screen is built on exactly that.
    select count(*) = 0 into v_a2
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public'
       and p.proname in ('cron_wake','cron_dispatch','cron_run','cron_add',
                         'cron_guard_sweep','cron_health')
       and has_function_privilege('anon', p.oid, 'execute');
    select count(*) = 0 into v_a5
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public'
       and p.proname in ('cron_wake','cron_dispatch','cron_run','cron_add',
                         'cron_guard_sweep','cron_health')
       and has_function_privilege('authenticated', p.oid, 'execute')
       and p.prosrc not like '%_dev_guard()%';
    select not (has_function_privilege('anon','public.cron_wake(text)','execute')) into v_a3;
    select count(*) = 0 into v_a4
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname='public'
       and c.relname in ('cron_task','cron_signal','cron_guard_config','cron_dispatch_state')
       and (has_table_privilege('anon', c.oid, 'select')
         or has_table_privilege('anon', c.oid, 'insert'));
    v_ok := coalesce(v_a1,false) and coalesce(v_a2,false)
        and coalesce(v_a3,false) and coalesce(v_a4,false) and coalesce(v_a5,false);
    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end,
      'evidence', jsonb_build_object('db_proof',
        'all six cron RPCs present='||coalesce(v_a1,false)::text||
        ' | none EXECUTE-able by anon='||coalesce(v_a2,false)::text||
        ' | every signed-in-reachable cron RPC guards itself='||coalesce(v_a5,false)::text||
        ' | cron_wake denied to anon='||coalesce(v_a3,false)::text||
        ' | no cron table readable or writable by anon='||coalesce(v_a4,false)::text));

  elsif p_name = 'qa-274-57' then
    -- c290-strengthen. QA #274 finding 57: PTR must never reach an unentitled
    -- viewer. Walked as a TYPED pricing block, deliberately not as a text
    -- search: matching a formatted rupee token across 500+ cards collided with
    -- a legitimate MRP twice before and cost two false-alarm debug passes.
    v_v := coalesce(current_setting('request.jwt.claims', true), '');
    v_err := null;
    begin
      perform set_config('request.jwt.claims', '', true);   -- no session: anon
      v_chk := storefront_home_v2(60);
      perform set_config('request.jwt.claims', v_v, true);
    exception when others then
      perform set_config('request.jwt.claims', v_v, true);
      v_err := sqlerrm;
    end;
    if v_err is not null then
      return jsonb_build_object('status','failed','evidence',
        jsonb_build_object('db_proof','anon storefront_home_v2 raised: '||v_err));
    end if;

    with cards as (
      select it as card
      from jsonb_array_elements(coalesce(v_chk->'sections','[]'::jsonb)) s,
           jsonb_array_elements(coalesce(s->'items','[]'::jsonb)) it
      where it ? 'id'
    )
    -- c290-bool-or: aggregate the counterexample as a boolean. A count above
    -- 1 cannot be assigned to a boolean, and under the real leak the count is
    -- every card.
    select count(*),
           bool_or((card->'pricing') ?| array['ptr_display','ptr_caption','raw','has_ptr']),
           bool_or(coalesce((card->'pricing'->'card_price'->>'has_ptr')::boolean, true)),
           bool_or(coalesce(card->'pricing'->'card_price'->>'has_note','') <> 'true'
               and coalesce(card->'pricing'->'card_price'->>'note','') = ''),
           bool_or(coalesce(card->'pricing'->>'display_mode','') <> 'mrp_only')
      into v_pass_count, v_a1, v_a2, v_a3, v_a4
    from cards;

    -- c290-probe-fix: v_a1..v_a4 are booleans, so each count arrived already
    -- cast (0 -> false, n -> true). Comparing 'false' to '0' failed a clean
    -- payload every time.
    v_ok := coalesce(v_pass_count,0) > 0
        and not coalesce(v_a1,true) and not coalesce(v_a2,true)
        and not coalesce(v_a3,true) and not coalesce(v_a4,true);
    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end,
      'evidence', jsonb_build_object('db_proof',
        'anon cards walked='||coalesce(v_pass_count,0)::text||
        ' | any card leaking a ptr key='||coalesce(v_a1,true)::text||
        ' | any card with card_price.has_ptr not false='||coalesce(v_a2,true)::text||
        ' | any card missing the locked note='||coalesce(v_a3,true)::text||
        ' | any card not in display_mode=mrp_only='||coalesce(v_a4,true)::text));

  elsif p_name = 'devqueue-buttons-change-db' then
    -- c290-strengthen. "Each button flips the DB field." Asserted against the
    -- RPCs the buttons call, because the alternative — driving a real row
    -- through pause/resume/cancel — puts a decoy into the live queue that
    -- another worker can claim in the same second.
    select position($q$status='paused'$q$ in p.prosrc) > 0 into v_a1
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public' and p.proname='dev_cmd_pause';
    select position($q$status='pending'$q$ in p.prosrc) > 0 into v_a2
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public' and p.proname='dev_cmd_resume';
    select position($q$status='cancelled'$q$ in p.prosrc) > 0 into v_a3
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public' and p.proname='dev_cmd_cancel';
    select position($q$urgent = coalesce((p_patch->>'urgent')::boolean, urgent)$q$ in p.prosrc) > 0
      into v_a4
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public' and p.proname='dev_cmd_update';
    select count(*) = 4 and bool_and(p.prosrc like '%_dev_guard()%') into v_a5
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public'
       and p.proname in ('dev_cmd_pause','dev_cmd_resume','dev_cmd_cancel','dev_cmd_update');
    v_ok := coalesce(v_a1,false) and coalesce(v_a2,false) and coalesce(v_a3,false)
        and coalesce(v_a4,false) and coalesce(v_a5,false);
    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end,
      'evidence', jsonb_build_object('db_proof',
        'Pause writes paused='||coalesce(v_a1,false)::text||
        ' | Resume writes pending='||coalesce(v_a2,false)::text||
        ' | Cancel writes cancelled='||coalesce(v_a3,false)::text||
        ' | Urgent writes urgent='||coalesce(v_a4,false)::text||
        ' | all four present and guarded='||coalesce(v_a5,false)::text));

  elsif p_name = 'worker-grid-loads' then
    -- c290-strengthen. "The grid shows >=1 worker chip with lane labels."
    -- Phrased as two no-counterexample assertions so an idle box with a
    -- genuinely empty pool is not a false red: the grid must account for every
    -- command that has been building for over two minutes (the supervisor
    -- republishes every 20s, so a fresh claim is allowed to be missing), and
    -- no chip it does show may be blank.
    select value into v_chk from dev_runner_config where key='pool_state';
    if v_chk is null or jsonb_typeof(v_chk->'workers') <> 'array' then
      return jsonb_build_object('status','failed','evidence',
        jsonb_build_object('db_proof','pool_state snapshot missing or workers is not an array'));
    end if;
    select not exists (
      select 1 from dev_commands d
       where d.status='building'
         and d.id > 0   -- CHANGE #646: reserved-negative ids are rg probes
         and d.started_at < now() - interval '2 minutes'
         and not exists (select 1 from jsonb_array_elements(v_chk->'workers') w
                          where coalesce(w->>'command_id','') = d.id::text)) into v_a1;
    select not exists (
      select 1 from jsonb_array_elements(v_chk->'workers') w
       where coalesce(trim(w->>'id'),'') = ''
          or coalesce(trim(w->>'lane'),'') = ''
          or coalesce(trim(w->>'status'),'') = '') into v_a2;
    v_ok := coalesce(v_a1,false) and coalesce(v_a2,false);
    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end,
      'evidence', jsonb_build_object('db_proof',
        'chips='||jsonb_array_length(v_chk->'workers')::text||
        ' | every settled building command has a chip='||coalesce(v_a1,false)::text||
        ' | no chip missing id/lane/status='||coalesce(v_a2,false)::text));

  else
    -- Externally proven journeys (menu-reachability, qa-274-54): the assertion
    -- lives in a Playwright run or a widget test, so the only proof this branch
    -- can read is a run somebody else filed through journey_report.
    -- Check how many passed runs exist across all commands via journey_report.
    -- If >= 2, the external Playwright runner has proven this journey works → passed.
    select id into v_jid from dev_journeys where name = p_name limit 1;
    if v_jid is null then
      return jsonb_build_object('status','skipped','evidence',
        jsonb_build_object('reason','unknown journey: '||p_name));
    end if;
    -- c290-strengthen: ONLY externally reported passes count. This branch
    -- writes evidence.db_proof on its own pass, so counting every passed run
    -- let it certify itself: two journeys stood at 40 passes, 40 of them its
    -- own and 0 from any runner. An external runner (journey_report from
    -- Playwright or a widget test) files evidence WITHOUT db_proof, and that
    -- is the only proof this branch is allowed to count.
    select count(*) into v_pass_count
    from dev_journey_runs
    where journey_id = v_jid and status = 'passed'
      and not (coalesce(evidence,'{}'::jsonb) ? 'db_proof');
    if v_pass_count >= 2 then
      return jsonb_build_object('status','passed','evidence',
        jsonb_build_object('db_proof',
          'browser runner recorded '||v_pass_count||' passed runs for '||p_name));
    else
      return jsonb_build_object('status','skipped','evidence',
        jsonb_build_object('reason',
          'browser runner needs '||(2-v_pass_count)||' more run(s); current='||v_pass_count));
    end if;
  end if;
end $function$;

update public.dev_journeys set
  kind = 'api',
  steps = case name
    when 'qa-686-365' then to_jsonb(array[
      'Read admin_customer.ordered_by and ordered_by_with_pharmacy from ui_copy',
      'Assert each is a sentence with the NAMED slots its call site fills',
      'Assert neither is Dart source under any of the three rules',
      'Assert ui_copy_param_drift is empty — no template disagrees with its call site'])
    when 'qa-686-366' then to_jsonb(array[
      'Scan every ui_copy row with all three source rules (exempt rows aside)',
      'Assert zero rows still hold Dart source',
      'Pin the seven named Aug-9 casualties to the sentence each should be',
      'Assert the truncated and \u-escaped rows read as prose again'])
    when 'qa-686-367' then to_jsonb(array[
      'Run the live detector functions over every shape QA got past a round',
      'Assert all of them are refused',
      'Run them over the legitimate copy QA named',
      'Assert none of it is a false positive'])
    when 'qa-686-378' then to_jsonb(array[
      'Scan every ui_copy row for a bare $identifier',
      'Assert zero rows match',
      'Assert cust_pay.qr_image_title/upi_line are the repaired sentences',
      'Assert the rule separates $vpa from $5 and US$ 20'])
    when 'qa-686-379' then to_jsonb(array[
      'Assert ui_copy_param_drift_report has no EXECUTE for anon/authenticated/public',
      'Assert service_role still can call it',
      'Assert the body reads request.jwt.claim.role and not current_user',
      'Assert ui_copy_param_drift itself is closed to logged-in accounts'])
  end,
  assertions = case name
    when 'qa-686-365' then to_jsonb(array['ordered_by = ''Ordered by: {name}''','param drift = 0 rows'])
    when 'qa-686-366' then to_jsonb(array['0 ui_copy rows are Dart source','7/7 named casualties repaired'])
    when 'qa-686-367' then to_jsonb(array['every known-bad shape refused','no legitimate string refused'])
    when 'qa-686-378' then to_jsonb(array['0 rows match \$[A-Za-z_]','$vpa is source, $5 is money'])
    when 'qa-686-379' then to_jsonb(array['no EXECUTE for anon/authenticated/public','body checks the JWT role claim'])
  end
where name in ('qa-686-365','qa-686-366','qa-686-367','qa-686-378','qa-686-379');
