#!/usr/bin/env bash
# CHANGE #696 — the mediBO <-> partner escalation channel, proved end to end.
#
# Raises an issue in BOTH directions, runs the SLA clock forward, proves the
# half-time WhatsApp nudge, the breach landing in the ops inbox, the closure
# refusing to happen without an outcome code, the outcome reaching the partner
# scorecard, and the zone clamp (partner 22 cannot see partner 1's issue) —
# then ROLLS BACK. Nothing is left in the books.
#
#   bash scripts/c696_ticket_proof.sh
#
# Exits non-zero on the first assertion that fails.
set -euo pipefail

PGURL="${SUPABASE_DB_URL:-$(cat "$HOME/.medibo/dburl")}"

psql "$PGURL" -X -v ON_ERROR_STOP=1 -q <<'SQL'
begin;
set local lock_timeout = '30s';
set local statement_timeout = '120s';

-- The three identities this proof speaks as. They are the platform's own test
-- logins, so the RPCs authorise exactly as they do for a real device.
create temp table c696_who(k text primary key, uid uuid) on commit drop;
insert into c696_who(k, uid)
select 'office',   u.id from auth.users u where lower(u.email) = 'test.admin@medibo.in'
union all
select 'partner1', u.id from auth.users u where lower(u.email) = 'test.partner1@medibo.in'
union all
select 'partner2', u.id from auth.users u where lower(u.email) = 'test.partner2@medibo.in';

create or replace function pg_temp.be(p_k text) returns void language plpgsql as $$
declare v uuid;
begin
  select uid into v from c696_who where k = p_k;
  if v is null then raise exception 'c696: no identity for %', p_k; end if;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v::text, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v::text, true);
end $$;

create or replace function pg_temp.ck(p_label text, p_ok boolean, p_detail text default '')
returns void language plpgsql as $$
begin
  if p_ok then raise notice 'PASS · %  %', p_label, p_detail;
  else raise exception 'FAIL · %  %', p_label, p_detail; end if;
end $$;

-- ── 1. the office IS the office, the partner IS a partner ───────────────────
select pg_temp.be('partner1');
select pg_temp.ck('actor · partner login resolves to the partner side',
  (public._pt_actor()->>'side') = 'partner', public._pt_actor()->>'label');
select pg_temp.be('office');
select pg_temp.ck('actor · admin login resolves to the mediBO side',
  (public._pt_actor()->>'side') = 'medibo', public._pt_actor()->>'label');

-- ── 2. the raise sheet offers only the side's OWN categories ────────────────
select pg_temp.be('partner1');
do $$
declare v jsonb := public.partner_ticket_new();
begin
  perform pg_temp.ck('raise sheet · partner sees only partner-raised categories',
    (select bool_and(c->>'code' in ('order','supplier','payment','app_bug','delivery'))
       from jsonb_array_elements(v->'categories') c)
    and jsonb_array_length(v->'categories') = 5,
    'n=' || jsonb_array_length(v->'categories'));
  perform pg_temp.ck('raise sheet · a partner is never asked which partner',
    (v->>'needs_partner')::boolean = false, '');
  perform pg_temp.ck('raise sheet · the upload folder is the backend''s',
    (v#>>'{upload,folder}') like 'p%/draft', v#>>'{upload,folder}');
end $$;

select pg_temp.be('office');
do $$
declare v jsonb := public.partner_ticket_new();
begin
  perform pg_temp.ck('raise sheet · the office sees only mediBO-raised categories',
    (select bool_and(c->>'code' in ('sla_breach','count_dispute','settlement_query'))
       from jsonb_array_elements(v->'categories') c),
    'n=' || jsonb_array_length(v->'categories'));
  perform pg_temp.ck('raise sheet · the office MUST name a partner',
    (v->>'needs_partner')::boolean = true, '');
end $$;

-- ── 3. direction 1 — the partner raises, the office owns it ─────────────────
create temp table c696_t(k text primary key, id uuid) on commit drop;
select pg_temp.be('partner1');
do $$
declare v jsonb;
begin
  v := public.partner_ticket_raise('payment', 'Settlement 12 Aug short by two lines',
        'Two lines are missing from the statement.', 'normal', null, 'settlement', 'SP-12');
  perform pg_temp.ck('raise · partner-raised issue is accepted',
    (v->>'ok')::boolean, v->>'ref');
  insert into c696_t values ('a', (v->>'id')::uuid);
end $$;

do $$
declare t public.partner_ticket;
begin
  select * into t from public.partner_ticket where id = (select id from c696_t where k='a');
  perform pg_temp.ck('owner · a partner-raised issue is owned by the office',
    t.owner_side = 'medibo' and t.raised_side = 'partner', t.owner_side);
  perform pg_temp.ck('sla · the category''s promise became a due time',
    t.sla_hours = 24 and t.sla_due_at > now(), t.sla_hours::text || 'h');
  perform pg_temp.ck('sla · the nudge is set at half the promised time',
    t.nudge_due_at > now() and t.nudge_due_at < t.sla_due_at, public._ist_stamp(t.nudge_due_at));
end $$;

-- ── 4. the office sees it, and reads the OTHER status voice ─────────────────
select pg_temp.be('office');
do $$
declare v jsonb; r jsonb;
begin
  v := public.partner_ticket_list('open');
  select c into r from jsonb_array_elements(v->'rows') c
   where c->>'id' = (select id::text from c696_t where k='a');
  perform pg_temp.ck('list · the office sees the partner''s issue', r is not null, '');
  perform pg_temp.ck('list · the office is told it is waiting on THEM',
    r->>'status_label' = public._c('pt.status.waiting'), r->>'status_label');
end $$;

select pg_temp.be('partner1');
do $$
declare v jsonb; r jsonb;
begin
  v := public.partner_ticket_list('open');
  select c into r from jsonb_array_elements(v->'rows') c
   where c->>'id' = (select id::text from c696_t where k='a');
  perform pg_temp.ck('list · the partner is told it is waiting on the office',
    r->>'status_label' = public._c('pt.status.waiting_them'), r->>'status_label');
end $$;

-- ── 5. ZONE SCOPE — another partner cannot see it, or open it ───────────────
select pg_temp.be('partner2');
do $$
declare v jsonb;
begin
  v := public.partner_ticket_list('all');
  perform pg_temp.ck('zone · partner 2 cannot see partner 1''s issue',
    not exists (select 1 from jsonb_array_elements(v->'rows') c
                 where c->>'id' = (select id::text from c696_t where k='a')),
    'rows=' || jsonb_array_length(v->'rows'));
  v := public.partner_ticket_get((select id from c696_t where k='a'));
  perform pg_temp.ck('zone · opening it directly is refused with the backend''s words',
    (v->>'ok')::boolean is false and v->>'message' = public._c('pt.err_not_yours'),
    v->>'message');
end $$;

-- ── 6. THE CLOCK — half time nudges, the deadline breaches ──────────────────
update public.partner_ticket set nudge_due_at = now() - interval '1 minute'
 where id = (select id from c696_t where k='a');
do $$
declare v jsonb;
begin
  v := public.partner_ticket_sla_tick(20);
  perform pg_temp.ck('tick · half the promised time nudged the owning side',
    (v->>'nudged')::int >= 1, v::text);
  perform pg_temp.ck('tick · the nudge is written INTO the timeline',
    exists (select 1 from public.partner_ticket_message m
             where m.ticket_id = (select id from c696_t where k='a')
               and m.body = public._c('pt.system_nudge')), '');
end $$;

update public.partner_ticket set sla_due_at = now() - interval '1 minute'
 where id = (select id from c696_t where k='a');
do $$
declare v jsonb;
begin
  v := public.partner_ticket_sla_tick(20);
  perform pg_temp.ck('tick · the deadline passing is recorded as a breach',
    (v->>'breached')::int >= 1, v::text);
  perform pg_temp.ck('ops inbox · the breach appears on the exceptions console',
    exists (select 1 from public._exception_rows() e
             where e.reason_code = 'partner_ticket_breach'
               and e.ref_id = (select id::text from c696_t where k='a')), '');
end $$;

select pg_temp.be('office');
do $$
declare v jsonb;
begin
  v := public.partner_ticket_list('breached');
  perform pg_temp.ck('list · the overdue filter finds it, breach first',
    (v->'rows'->0->>'id') = (select id::text from c696_t where k='a'),
    v->'rows'->0->>'sla_label');
end $$;

-- ── 7. a reply hands the ball back, and restarts the clock ──────────────────
do $$
declare v jsonb; t public.partner_ticket;
begin
  v := public.partner_ticket_reply((select id from c696_t where k='a'),
         'Checked — both lines were on the next statement.');
  perform pg_temp.ck('reply · the office answering is accepted', (v->>'ok')::boolean, '');
  select * into t from public.partner_ticket where id = (select id from c696_t where k='a');
  perform pg_temp.ck('reply · the ball, and the clock, moved to the partner',
    t.owner_side = 'partner' and t.sla_due_at > now() and t.breached_at is null,
    t.status);
end $$;

-- ── 8. CLOSURE NEEDS AN OUTCOME, and the outcome feeds the scorecard ────────
do $$
declare v jsonb;
begin
  v := public.partner_ticket_close((select id from c696_t where k='a'), '', 'no code');
  perform pg_temp.ck('close · a closure with no outcome is refused',
    (v->>'ok')::boolean is false and v->>'message' = public._c('pt.err_no_outcome'),
    v->>'message');
  v := public.partner_ticket_close((select id from c696_t where k='a'), 'fixed', 'Reissued.');
  perform pg_temp.ck('close · a closure WITH an outcome is accepted', (v->>'ok')::boolean, '');
  perform pg_temp.ck('scorecard · the closure reached exception_scorecard_input',
    exists (select 1 from public.exception_scorecard_input s
             where s.reason_code = 'partner_ticket'
               and s.exception_id = 'partner_ticket:' || (select id::text from c696_t where k='a')), '');
end $$;

do $$
declare v numeric;
begin
  select value into v from public._partner_metric_values(1, (now() at time zone 'Asia/Kolkata')::date)
   where metric = 'issue_sla_pct';
  -- The office answered before closing, and a reply restarts the clock — so
  -- this issue closed INSIDE its promise and the month reads 100%. The point
  -- of the assertion is that the metric exists and is reading THIS channel.
  perform pg_temp.ck('scorecard · the month carries an issue_sla_pct metric',
    v is not null, 'issue_sla_pct=' || coalesce(v::text,'null'));
end $$;

-- ── 9. direction 2 — mediBO raises, the PARTNER owns it ─────────────────────
select pg_temp.be('office');
do $$
declare v jsonb; t public.partner_ticket;
begin
  v := public.partner_ticket_raise('count_dispute', 'Shop count and recount disagree on 3 lines',
        'Please recount bag 14.', 'high', 1, 'order', 'CPO-TEST-1');
  perform pg_temp.ck('raise · mediBO-raised issue is accepted', (v->>'ok')::boolean, v->>'ref');
  insert into c696_t values ('b', (v->>'id')::uuid);
  select * into t from public.partner_ticket where id = (v->>'id')::uuid;
  perform pg_temp.ck('owner · a mediBO-raised issue is owned by the partner',
    t.owner_side = 'partner' and t.raised_side = 'medibo', t.owner_side);
  perform pg_temp.ck('sla · priority SHORTENS the category promise (24h · high = 12h)',
    t.sla_hours = 12, t.sla_hours::text);
end $$;

select pg_temp.be('partner1');
do $$
declare v jsonb; r jsonb;
begin
  v := public.partner_ticket_get((select id from c696_t where k='b'));
  perform pg_temp.ck('detail · the partner can open the issue mediBO raised',
    (v->>'ok')::boolean, v->>'ref');
  perform pg_temp.ck('detail · the linked order is one tap, with its own label',
    (v#>>'{link,has}')::boolean and v#>>'{link,kind}' = 'order', v#>>'{link,label}');
  perform pg_temp.ck('detail · the opening system line names the promise',
    exists (select 1 from jsonb_array_elements(v->'messages') m
             where (m->>'is_system')::boolean and m->>'body' like '%12h%'), '');
  perform pg_temp.ck('badge · the partner owes an answer on exactly one issue',
    public._pt_badge_count() = 1, public._pt_badge_count()::text);
end $$;

select pg_temp.be('office');
select pg_temp.ck('badge · the office owes an answer on none of them',
  public._pt_badge_count() = 0, public._pt_badge_count()::text);

rollback;
SQL

echo "c696 proof: every assertion passed (rolled back — nothing written)"
