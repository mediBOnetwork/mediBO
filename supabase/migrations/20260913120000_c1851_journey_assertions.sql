-- CMD #1851 — two required storefront journeys that no longer describe the
-- product they guard, repaired as assertions rather than worked around.
--
-- Both had been red on every command since #1848 (lesson 302) and both were
-- read as cast drift. They are not: the code they assert against changed
-- deliberately, and the assertion did not follow.
--
-- Neither function is edited in place. `_dev_journey_by_convention()` is
-- consulted BEFORE the dispatcher's hand-written branches (CHANGE #705), and
-- it maps a journey name to `_journey_` || the name with every run of
-- non-alphanumerics collapsed to '_'. So 'bug-633' resolves to
-- `_journey_bug_633` and 'qa-274-57' to `_journey_qa_274_57` — names the
-- branch journey seeds do not carry, which is the point: a branch that
-- re-applies those seeds cannot overwrite what is defined here.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. A DELIBERATE ANON GRANT IS REGISTERED, NOT INVISIBLE.
--    bug-633 sweeps for an admin_% function anon can execute. admin_scope_chip
--    is granted to anon ON PURPOSE — the header calls it before a session
--    resolves and the function answers show:false to everyone who is not staff
--    — so the sweep reported a leak that is not one, on live as well as on a
--    branch. rpc_anon_allow is the register the codebase already keeps for
--    exactly this (_journey_bug436 and _journey_bug683 both read it); the
--    sweep now reads it too, so a NEW admin_% grant still fails the journey.
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.rpc_anon_allow (fn_name, reason)
select 'admin_scope_chip',
       'Staff header chip. anon calls it before a session resolves; the body '
       || 'answers show:false to anyone who is not partner/staff, so it carries '
       || 'its own guard and returns no admin data.'
 where not exists (select 1 from public.rpc_anon_allow where fn_name = 'admin_scope_chip');

create or replace function public._journey_bug_633()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $c1851$
declare
  v_a1 boolean; v_a2 boolean; v_a3 boolean; v_a4 boolean; v_ok boolean;
  v_open int; v_leaks text; v_log record; v_slots int; v_fresh boolean;
begin
  v_a1 := exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'admin_customer_screen_data');

  select count(*), coalesce(string_agg(p.proname, ', ' order by p.proname), '')
    into v_open, v_leaks
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f'
     and p.proname like 'admin\_%'
     and has_function_privilege('anon', p.oid, 'execute')
     and not exists (select 1 from public.rpc_anon_allow a where a.fn_name = p.proname);
  v_a2 := v_open = 0;

  select * into v_log from public.render_log where id = 'singleton';
  -- Freshness matters more here than anywhere: "no placeholder was rendered"
  -- is trivially true of a log nobody has written to.
  v_fresh := v_log.id is not null
         and v_log.updated_at > now() - interval '3 days'
         and coalesce(v_log.build_hash,'') ~ '^[0-9a-f]{7,40}$';
  v_a3 := v_fresh and not (coalesce(v_log.data,'{}'::jsonb) ? 'c633_raw_placeholder');

  select count(*) into v_slots from public.ui_copy
   where key in ('admin_customer.failed_to_load','admin_customer.toast_failed_to_load')
     and value::text like '%{e}%';
  v_a4 := v_slots = 2;

  v_ok := v_a1 and v_a2 and v_a3 and v_a4;
  return jsonb_build_object(
    'status', case when v_ok then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'subject present='              || coalesce(v_a1,false)::text ||
      ' | unregistered admin_% reachable by anon=' || v_open::text ||
      case when v_open > 0 then ' (' || v_leaks || ')' else '' end ||
      ' | registered on rpc_anon_allow='
        || (select count(*)::text from public.rpc_anon_allow) ||
      ' | render log build='          || coalesce(v_log.build_hash,'(none)') ||
      ' fresh='                       || coalesce(v_fresh,false)::text ||
      ' raw_placeholder_seen='        || (coalesce(v_log.data,'{}'::jsonb) ? 'c633_raw_placeholder')::text ||
      ' | {e} still in both templates=' || coalesce(v_a4,false)::text));
end $c1851$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. THE LOCKED PRICE MOVED OFF THE CARD (CHANGE #1895).
--    qa-274-57 walks every anon storefront card and demands that PTR never
--    reaches an unentitled viewer. One of its four assertions read the card's
--    own `note`/`has_note` slot — and #1895 deliberately emptied both, because
--    the sentence became the sheet's note instead. _pricing_block() now writes
--    'has_note', false and 'note', '' unconditionally, so that assertion is
--    false for every card, forever, by design.
--    The CLASS is unchanged and still worth guarding: an anon card must carry
--    no PTR key, must say has_ptr=false, must be display_mode=mrp_only, and
--    must TELL the reader the trade price is locked. It tells them through
--    price_locked + locked_note now, so that is what is asserted.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._journey_qa_274_57()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $c1851$
declare
  v_v text; v_err text; v_chk jsonb;
  v_cards int; v_a1 boolean; v_a2 boolean; v_a3 boolean; v_a4 boolean; v_ok boolean;
begin
  v_v := coalesce(current_setting('request.jwt.claims', true), '');
  begin
    perform set_config('request.jwt.claims', '', true);   -- no session: anon
    v_chk := public.storefront_home_v2(60);
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
  -- Each counterexample is aggregated as a boolean: under a real leak the
  -- count is every card, and a count above 1 cannot be assigned to a boolean.
  select count(*),
         bool_or((card->'pricing') ?| array['ptr_display','ptr_caption','raw','has_ptr']),
         bool_or(coalesce((card->'pricing'->'card_price'->>'has_ptr')::boolean, true)),
         -- #1895: the card says the price is locked and names the locked note;
         -- the sentence itself is rendered by the sheet, not by the card.
         bool_or(coalesce((card->'pricing'->'card_price'->>'price_locked')::boolean, false) = false
             or  coalesce(card->'pricing'->'card_price'->>'locked_note','') = ''),
         bool_or(coalesce(card->'pricing'->>'display_mode','') <> 'mrp_only')
    into v_cards, v_a1, v_a2, v_a3, v_a4
  from cards;

  v_ok := coalesce(v_cards,0) > 0
      and not coalesce(v_a1,true) and not coalesce(v_a2,true)
      and not coalesce(v_a3,true) and not coalesce(v_a4,true);
  return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'anon cards walked='||coalesce(v_cards,0)::text||
      ' | any card leaking a ptr key='||coalesce(v_a1,true)::text||
      ' | any card with card_price.has_ptr not false='||coalesce(v_a2,true)::text||
      ' | any card not marked price_locked with a locked note='||coalesce(v_a3,true)::text||
      ' | any card not in display_mode=mrp_only='||coalesce(v_a4,true)::text));
end $c1851$;
