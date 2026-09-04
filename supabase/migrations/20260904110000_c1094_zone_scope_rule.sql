-- CHANGE #1094 — zone and date scoping stops being a lesson and becomes a gate.
--
-- Om, 4 Sep: "make zone + date scoping automatic and permanent, not a lesson."
--
-- THE ONE-TIME AUDIT, RUN FIRST, IS WHY THIS IS A RATCHET AND NOT A WALL.
-- Of the 520 staff-facing functions the spec's name patterns match, 134 read
-- rows of orders / deliveries / inquiries / supplier_orders / pending_bills.
-- Exactly FIVE of those reference both a zone helper and admin_active_date();
-- 126 reference no zone helper at all. A gate that failed on any violator would
-- have gone red the moment it was enabled and blocked every completion in the
-- fleet — the same mistake CLAUDE.md already warns about for bugloop.enforce.
--
-- So the gate is shaped like the design-literal gate that already works here:
--   * today's 126 are captured ONCE in zone_scope_baseline — grandfathered,
--     visible, and counted as debt;
--   * a function that is NEW, or whose body CHANGED, and is still unscoped,
--     turns the guard RED naming it. That is exactly the spec's "scan every
--     new/changed function created by a command";
--   * the baseline RATCHETS DOWN ONLY: fix a function and it leaves the
--     baseline for good, and can never be re-added silently;
--   * zone_scope_allow is the escape hatch for genuinely global surfaces
--     (the catalogue, MEDICINE, the platform's own plumbing), editable by a
--     super admin, and every entry carries a written reason.

-- ── 1. the allow-list: functions that are global ON PURPOSE ────────────────
create table if not exists public.zone_scope_allow (
  fn_pattern  text primary key,
  reason      text not null,
  -- 'both' = global on purpose, exempt from the whole rule.
  -- 'date' = correctly zone-scoped, but has no date dimension to scope BY —
  --          a live backlog is not a day's ledger. The zone half still binds.
  dimension   text not null default 'both'
              check (dimension in ('both','date')),
  added_by    text,
  added_at    timestamptz not null default now()
);
alter table public.zone_scope_allow
  add column if not exists dimension text not null default 'both';
comment on table public.zone_scope_allow is
  'CHANGE #1094 — staff-facing functions that are global on purpose. '
  'fn_pattern is matched with LIKE against the function NAME. Every row needs '
  'a written reason; a super admin edits this, nobody else.';
alter table public.zone_scope_allow enable row level security;

insert into public.zone_scope_allow (fn_pattern, reason, added_by) values
  ('%catalog%',        'The catalogue is one national product list; a zone does not own a molecule.', 'CHANGE #1094'),
  ('%catalogue%',      'Same list, the other spelling.', 'CHANGE #1094'),
  ('%medicine%',       'MEDICINE is the national master; scoping it would hide stock that exists.', 'CHANGE #1094'),
  ('%_product%',       'Product identity is global; availability is what is zoned, and that is scoped where it is read.', 'CHANGE #1094'),
  ('admin_zone%',      'The zone picker itself must see every zone or it cannot offer them.', 'CHANGE #1094'),
  ('admin_active%',    'The scope helpers ARE the scope; they cannot scope themselves.', 'CHANGE #1094'),
  ('zone_%',           'The zone plumbing.', 'CHANGE #1094'),
  ('admin_can%',       'Access checks answer for a person, not for a zone of rows.', 'CHANGE #1094'),
  ('partner_can%',     'Same, on the partner side.', 'CHANGE #1094'),
  ('admin_audit%',     'The audit trail is deliberately global — a zoned audit log is not an audit log.', 'CHANGE #1094'),
  ('%_rpc_allow%',     'RPC allow-lists are platform plumbing.', 'CHANGE #1094')
on conflict (fn_pattern) do update set reason = excluded.reason;

-- Zone-scoped, but dateless on purpose: a live backlog has no day to scope by.
insert into public.zone_scope_allow (fn_pattern, reason, dimension, added_by) values
  ('fw_list_unfillable', 'A live unfillable backlog is a queue, not a day''s ledger — it has no date dimension. The zone half still binds and was added in #1094.', 'date', 'CHANGE #1094')
on conflict (fn_pattern) do update
  set reason = excluded.reason, dimension = excluded.dimension;

-- ── 2. the baseline: the debt this change inherited, named ─────────────────
create table if not exists public.zone_scope_baseline (
  fn_name     text primary key,
  sig         text not null,
  body_md5    text not null,
  captured_at timestamptz not null default now(),
  note        text
);
comment on table public.zone_scope_baseline is
  'CHANGE #1094 — the staff RPCs that were already unscoped when the gate was '
  'built. Grandfathered so the gate could be switched on at all. body_md5 is '
  'the point: CHANGE the function and it no longer matches its baseline, so '
  'the gate judges it as new work and demands the scoping. Ratchets DOWN only.';
alter table public.zone_scope_baseline enable row level security;

-- ── 3. the audit itself, as one function both the report and the gate use ──
create or replace function public.zone_scope_audit(p_mode text default 'violations')
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  with cand as (
    select p.oid,
           p.proname as fn,
           p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' as sig,
           -- Comments are prose, not code: a function that merely MENTIONS
           -- orders in a note is not reading them.
           regexp_replace(pg_get_functiondef(p.oid), '--[^' || chr(10) || ']*', '', 'g') as src
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.prokind = 'f'
       and (p.proname like 'admin\_%'   or p.proname like 'partner\_%'
         or p.proname like 'fw\_%'      or p.proname like 'pack\_%'
         or p.proname like 'delivery\_%'or p.proname like 'dashboard%'
         or p.proname like '%\_screen\_data'
         or p.proname like '%\_list'    or p.proname like '%\_counts'
         or p.proname in ('ops_board','exceptions_queue'))
  ),
  judged as (
    select c.fn, c.sig, md5(c.src) as body_md5,
           -- The spec's words are "RETURNS ROWS of", so this is a READ test:
           -- from/join only. A mutation that updates one row by id is not a
           -- list surface, and catching partner_return_carry_apply — which
           -- writes a credit note against a single supplier order — taught
           -- that the difference matters.
           (c.src ~* ('\m(from|join)\s+(public\.)?"?'
                      || '(orders|deliveries|inquiries|supplier_orders|pending_bills)"?\M')) as reads_rows,
           -- scope_zone()/scope_date() ARE the canonical wrappers — scope_zone is
           -- literally coalesce(partner_zone_id(), p_zone, admin_active_zone()) and
           -- scope_date is coalesce(p_date, admin_active_date()). A detector that
           -- did not credit them called admin_delivery_queue a violation while it
           -- was doing precisely the right thing. partner_zone_id()/my_partner_id()
           -- count too: a partner is zone-locked, so resolving the partner IS the
           -- clamp. A raw zone_id filter is NOT credited — choosing the zone inside
           -- the screen instead of from the header picker is the anti-pattern this
           -- rule exists to stop.
           (c.src ~* 'admin_active_zone|zone_effective|scope_zone|partner_zone_id|my_zone_id|my_partner_id') as has_zone,
           (c.src ~* 'admin_active_date|scope_date')         as has_date,
           exists (select 1 from public.zone_scope_allow a
                    where c.fn like a.fn_pattern and a.dimension = 'both')   as allowed,
           exists (select 1 from public.zone_scope_allow a
                    where c.fn like a.fn_pattern and a.dimension = 'date')   as date_exempt,
           (select b.body_md5 from public.zone_scope_baseline b where b.fn_name = c.fn) as baseline_md5
      from cand c
  ),
  verdicted as (
    select fn, sig, body_md5, reads_rows, has_zone, has_date, allowed, date_exempt, baseline_md5,
           -- The order matters. `zone_only` (a zone helper but no date) used to
           -- sit ABOVE the baseline checks, which quietly exempted those three
           -- functions for ever — change one and it still could not fail. It
           -- is now judged exactly like an unscoped one: grandfathered while
           -- untouched, blocking the moment its body changes.
           case
             when not reads_rows           then 'not_applicable'
             when allowed                  then 'allowed'
             when has_zone and (has_date or date_exempt) then 'scoped'
             when baseline_md5 = body_md5  then 'grandfathered'
             when baseline_md5 is not null then 'changed_still_unscoped'
             else                               'new_unscoped'
           end as verdict
      from judged
  )
  select jsonb_build_object(
    'ok', true,
    'mode', p_mode,
    'counts', (select jsonb_object_agg(verdict, n)
                 from (select verdict, count(*) n from verdicted group by verdict) x),
    'blocking', (select coalesce(jsonb_agg(jsonb_build_object(
                          'fn', fn, 'sig', sig, 'verdict', verdict,
                          'has_zone', has_zone, 'has_date', has_date)
                        order by fn), '[]'::jsonb)
                   from verdicted
                  where verdict in ('new_unscoped','changed_still_unscoped')),
    'rows', case when p_mode = 'all' then
              (select coalesce(jsonb_agg(jsonb_build_object(
                        'fn', fn, 'sig', sig, 'verdict', verdict,
                        'has_zone', has_zone, 'has_date', has_date) order by fn), '[]'::jsonb)
                 from verdicted where reads_rows)
            when p_mode = 'violations' then
              (select coalesce(jsonb_agg(jsonb_build_object(
                        'fn', fn, 'sig', sig, 'verdict', verdict,
                        'has_zone', has_zone, 'has_date', has_date) order by fn), '[]'::jsonb)
                 from verdicted
                where verdict in ('new_unscoped','changed_still_unscoped','grandfathered'))
            else '[]'::jsonb end)
$function$;

-- ── 4. the baseline capture — ratchets DOWN only ───────────────────────────
-- Called once here. Calling it again can only REMOVE entries that have since
-- been scoped or allow-listed; it never grandfathers anything new, which is
-- what stops the gate being silently defeated by re-running it.
create or replace function public.zone_scope_baseline_capture(p_seed boolean default false)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_added int := 0; v_dropped int := 0; v_audit jsonb;
begin
  if p_seed then
    insert into public.zone_scope_baseline (fn_name, sig, body_md5, note)
    select r->>'fn', r->>'sig',
           (select md5(regexp_replace(pg_get_functiondef(p.oid), '--[^' || chr(10) || ']*', '', 'g'))
              from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname='public' and p.proname = r->>'fn' limit 1),
           'CHANGE #1094 initial capture'
      from jsonb_array_elements(public.zone_scope_audit('all')->'rows') r
     where r->>'verdict' = 'new_unscoped'
    on conflict (fn_name) do nothing;
    get diagnostics v_added = row_count;
  end if;

  -- the ratchet: anything now scoped, allow-listed or simply gone leaves.
  v_audit := public.zone_scope_audit('all');
  delete from public.zone_scope_baseline b
   where not exists (
     select 1 from jsonb_array_elements(v_audit->'rows') r
      where r->>'fn' = b.fn_name
        and r->>'verdict' in ('grandfathered','changed_still_unscoped','new_unscoped'));
  get diagnostics v_dropped = row_count;

  return jsonb_build_object('ok', true, 'added', v_added, 'dropped', v_dropped,
    'baseline_size', (select count(*) from public.zone_scope_baseline),
    'counts', public.zone_scope_audit('violations')->'counts');
end $function$;

select public.zone_scope_baseline_capture(true);

-- ── 5. the gate ────────────────────────────────────────────────────────────
insert into public.rg_behavior_tests (name, body, enabled, note) values
('c1094_staff_rpcs_are_zone_scoped', $rg$
do $b$
declare v jsonb; v_names text;
begin
  v := public.zone_scope_audit('violations');
  select string_agg(r->>'fn' || ' (' || (r->>'verdict') || ')', ', ' order by r->>'fn')
    into v_names
    from jsonb_array_elements(v->'blocking') r;
  if v_names is not null then
    raise exception 'RG_FAIL: staff RPC(s) read orders/deliveries/inquiries/supplier_orders/pending_bills without admin_active_zone()/zone_effective() AND admin_active_date(): %. Scope them (wrapper pattern: rename to _core, wrap and filter), or add a reasoned row to zone_scope_allow if the surface is global on purpose (CHANGE #1094).', v_names;
  end if;
  raise exception 'RG_ROLLBACK';
end $b$;
$rg$, true,
'CHANGE #1094 — every staff-facing list/count/report RPC is zone- and date-scoped. Only NEW or CHANGED functions can fail it: the 126 that were already unscoped when the gate was built are grandfathered in zone_scope_baseline, which ratchets down only.')
on conflict (name) do update set body = excluded.body, note = excluded.note, enabled = true;

-- ── 6. the rule, stored where a rebuilt VM will find it ────────────────────
insert into public.dev_runner_config (key, value)
values ('build_rules', jsonb_build_object(
  'zone_date_scoping', jsonb_build_object(
    'rule',
      'Every staff-facing list, count, report, feed or RPC (admin/partner) reads '
      'admin_active_zone() and admin_active_date() via zone_effective()/admin_active_date(); '
      'partner is zone-locked, super admin may see all zones; zone and date are chosen ONLY in '
      'the header picker, never per screen; customer/supplier surfaces scope to their own zone. '
      'New tables that hold orders/deliveries/inquiries/bills carry zone_id and inherit it by '
      'trigger. Use the wrapper pattern (rename to _core, wrap + filter) when touching large RPCs.',
    'gate', 'c1094_staff_rpcs_are_zone_scoped',
    'audit', 'select public.zone_scope_audit(''violations'')',
    'allow_list', 'public.zone_scope_allow (super admin edits; every row needs a reason)',
    'baseline', 'public.zone_scope_baseline (ratchets down only)',
    'change', 1094)))
on conflict (key) do update
  set value = dev_runner_config.value || excluded.value;

-- ── 7. the real fix the audit found ────────────────────────────────────────
-- fw_list_unfillable() takes no arguments and lists every unfillable line in
-- the platform. It is on partner_rpc_allow, and a partner is zone-locked by
-- policy — so a partner in one zone was reading the unfillable items of every
-- other zone. It is small, so it gets the clamp inline rather than the _core
-- wrapper; the payload keys are untouched.
create or replace function public.fw_list_unfillable()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v jsonb; v_zone smallint;
begin
  if get_my_role() not in ('admin','super_admin') then return jsonb_build_object('error','not_authorized'); end if;
  -- CHANGE #1094 — the header's zone, clamped to the partner's own. NULL means
  -- "all zones", which only a super admin who cleared the picker can produce.
  v_zone := public.scope_zone(null);
  select coalesce(jsonb_agg(jsonb_build_object(
            'order_item_id', oi.id,
            'order_id', oi.order_id,
            'product_id', oi.product_id,
            'product_name', oi.product_name,
            'pharmacy_name', oi.pharmacy_name,
            'qty', oi.quantity,
            'bag_no', oi.bag_no,
            'last_supplier', (select i.current_supplier from inquiry i where i.product_id=oi.product_id limit 1)
          ) order by oi.order_id), '[]'::jsonb)
    into v
  from order_items oi
  join orders o on o.id = oi.order_id
  left join pharmacy_profiles pp on pp.id = o.customer_id
  where oi.fulfillment_state = 'unfillable'
    and o.fulfillment_status not in ('shipped','cancelled')
    and (v_zone is null or coalesce(o.zone_id, pp.zone_id) = v_zone);
  return jsonb_build_object('status','ok','items',v);
end;
$function$;

-- ── 8. the rule where the runner reads its business truth ──────────────────
-- legal_get_page('about') is injected into every runner prompt, so the rule
-- travels with the business context and survives a VM rebuild.
update public.legal_pages
   set sections = (
     select jsonb_agg(s)
       from (
         select s from jsonb_array_elements(sections) s
          where s->>'heading' is distinct from 'Zone and date scoping'
         union all
         select jsonb_build_object(
           'heading', 'Zone and date scoping',
           'body',
             'Every staff-facing list, count, report, feed or RPC (admin/partner) reads '
             'admin_active_zone() and admin_active_date() via zone_effective()/admin_active_date() '
             '(scope_zone()/scope_date() are the canonical wrappers); partner is zone-locked, '
             'super admin may see all zones; zone and date are chosen ONLY in the header picker, '
             'never per screen; customer/supplier surfaces scope to their own zone. New tables that '
             'hold orders/deliveries/inquiries/bills carry zone_id and inherit it by trigger. Use the '
             'wrapper pattern (rename to _core, wrap + filter) when touching large RPCs. '
             'Enforced by rg behaviour test c1094_staff_rpcs_are_zone_scoped.')
       ) q)
 where slug = 'about'
   and not exists (select 1 from jsonb_array_elements(sections) s
                    where s->>'heading' = 'Zone and date scoping');

-- ── 9. fence the two functions this change added ───────────────────────────
-- Postgres creates every function with an implicit GRANT EXECUTE TO PUBLIC and
-- anon inherits it, so a SECURITY DEFINER function is a public endpoint until
-- it is explicitly revoked — and the anon key ships inside the web bundle and
-- the APK. `revoke ... from anon` alone is the trap: it leaves the PUBLIC grant
-- standing. Revoke PUBLIC, then re-grant the signed-in role, or the admin
-- screens lose their own RPC (the second branch of privileged_rpcs_are_not_anon).
-- Caught by that guard on this very change.
revoke all on function public.zone_scope_audit(text)                from public, anon;
revoke all on function public.zone_scope_baseline_capture(boolean)  from public, anon;
grant execute on function public.zone_scope_audit(text)             to authenticated, service_role;
-- The capture MUTATES the baseline, so it is service_role only: nobody signs in
-- and re-grandfathers their own unscoped RPC. `authenticated` needs its own
-- revoke — this schema hands it EXECUTE on new functions by default privilege,
-- so revoking PUBLIC alone leaves every signed-in user holding it.
revoke all on function public.zone_scope_baseline_capture(boolean) from authenticated;
grant execute on function public.zone_scope_baseline_capture(boolean) to service_role;
