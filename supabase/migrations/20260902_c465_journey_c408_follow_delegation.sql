-- CHANGE #465 · journey repair: qa-408-217 must follow the gate's delegation.
--
-- The journey greps the SOURCE of _order_edit_gate for the four predicates that
-- #408 put there: asked_at + supplier_order_id (a supplier has been asked) and
-- o.order_date + o.zone_id (the fallback without which the match went NULL).
--
-- _order_edit_gate has since been refactored: it is now a thin presenter that
-- delegates the whole decision to _order_change_gate and only dresses the
-- result (button_label / window_label / reason_code). Every predicate is still
-- enforced, one function further down. The BEHAVIOUR never changed — only the
-- address of the code did — so the probe went red on a refactor while the live
-- gate was correct throughout.
--
-- The repair is to assert over the gate CHAIN rather than one function name:
-- the predicates must exist somewhere in _order_edit_gate plus the helper it
-- delegates to. That is exactly as strong as before (delete asked_at from
-- _order_change_gate and this journey still goes red) and it stops the next
-- extract-a-helper refactor from failing a green build.
create or replace function public._journey_c408_window()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  a1 boolean; a2 boolean; a3 boolean; a4 boolean; a5 boolean;
  v_edit text; v_mos text; v_chain text;
begin
  select p.prosrc into v_edit from pg_proc p
   where p.pronamespace='public'::regnamespace and p.proname='_order_edit_gate';
  select p.prosrc into v_mos  from pg_proc p
   where p.pronamespace='public'::regnamespace and p.proname='my_orders_screen';

  -- The gate chain: the presenter plus every gate helper it calls by name.
  -- Concatenating the sources keeps a single grep while following delegation.
  v_chain := coalesce(v_edit,'');
  select v_chain || coalesce(string_agg(p.prosrc, E'\n'), '')
    into v_chain
    from pg_proc p
   where p.pronamespace='public'::regnamespace
     and p.proname in ('_order_change_gate')
     and position(p.proname in coalesce(v_edit,'')) > 0;

  -- bag_no is stamped at PLACEMENT, so it never meant "packing started".
  -- Absence is asserted over the WHOLE chain: re-introducing it anywhere in
  -- the gate is the regression #408 fixed.
  a1 := coalesce(position('oi.bag_no' in v_chain) = 0, false);
  -- the engine's own marker for "a supplier has been asked"
  a2 := coalesce(position('asked_at' in v_chain) > 0
             and position('supplier_order_id' in v_chain) > 0, false);
  -- and the fallback to the ORDER's date/zone, without which the match went NULL
  a3 := coalesce(position('o.order_date' in v_chain) > 0
             and position('o.zone_id' in v_chain) > 0, false);
  -- the window rides the order list …
  a4 := coalesce(position('_order_edit_gate' in coalesce(v_mos,'')) > 0, false);
  -- … and the caption rides with the flag, or the button renders nothing.
  -- The caption is the presenter's own job, so this one stays on _order_edit_gate.
  a5 := coalesce(position('button_label' in coalesce(v_edit,'')) > 0, false);

  return jsonb_build_object(
    'status', case when a1 and a2 and a3 and a4 and a5 then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'gate no longer reads bag_no=' || a1::text
   || ' | closes on asked_at/supplier_order_id=' || a2::text
   || ' | falls back to the order own date+zone=' || a3::text
   || ' | window rides my_orders_screen=' || a4::text
   || ' | and the button caption travels with the flag=' || a5::text));
end $function$;
