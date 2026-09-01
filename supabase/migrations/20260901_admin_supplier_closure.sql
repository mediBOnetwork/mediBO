-- cmd #435 — ADMIN-SIDE CLOSE / REOPEN for a supplier shop.
--
-- #401 shipped closed/holiday mode for the SUPPLIER (his own Availability page)
-- and read-only for admin. The admin WRITE endpoint has existed since that
-- command — `admin_supplier_set_closed(p_supplier, p_closed, p_until, p_reason)`,
-- already role-gated and already revoked from anon — with nothing wired to it.
-- The office could see that a shop was shut and could not shut it: a supplier
-- who phones in "we are closed for a funeral" had to be talked through his own
-- screen, or left to eat the timeouts this feature exists to prevent.
--
-- THE ONE DESIGN CHOICE HERE: the admin panel is NOT a second rendering of the
-- same state. #401 already learned, twice, what two definitions of one fact
-- cost (two definitions of "current supplier" parked 46 inquiries; two
-- definitions of "eligible" restored 14 of them). So `supplier_availability_get`
-- is REWRITTEN as a thin wrapper over the same builder the admin panel uses —
-- `_supplier_closure_panel(name, audience)` — and the audience picks the copy
-- keys, nothing else. A change to the closure payload lands on both surfaces or
-- neither; they cannot drift apart because there is only one of them.
--
-- No new Dart strings: every label, hint, button caption, chip and history line
-- below is a ui_copy row under `supplier.closed_*` / `supplier.avail_*`, and the
-- chip COLOURS come from app_settings.order_status_chips like every other chip
-- in the app (CHANGE #606), so recolouring the control is an UPDATE, not a
-- deploy.

-- ── one payload, two audiences ───────────────────────────────────────────────
create or replace function public._supplier_closure_panel(p_supplier text,
                                                          p_audience text default 'supplier')
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_name  text := btrim(coalesce(p_supplier, ''));
  v_admin boolean := coalesce(p_audience, 'supplier') = 'admin';
  v_state jsonb;
  v_chip  jsonb;
begin
  if v_name = '' then
    return jsonb_build_object('error', 'no_supplier');
  end if;

  v_state := public.supplier_closure_state(v_name);

  -- The chip the row paints: label from ui_copy, colours from the same chip
  -- config every other status chip reads. `status_chip` supplies show/bg/fg/
  -- border; the label is overridden so wording stays in ui_copy.
  v_chip := public.status_chip('supplier_closure',
              case when (v_state->>'closed')::boolean then 'closed' else 'open' end)
            || jsonb_build_object(
                 'label', case when (v_state->>'closed')::boolean
                               then _c('supplier.closed_chip_closed')
                               else _c('supplier.closed_chip_open') end,
                 'show', true);

  return v_state || jsonb_build_object(
    'ok',               true,
    'supplier_name',    v_name,
    'audience',         case when v_admin then 'admin' else 'supplier' end,
    'chip',             v_chip,
    'screen_title',     case when v_admin
                             then _cf('supplier.closed_admin_title',
                                      jsonb_build_object('supplier', v_name))
                             else _c('supplier.avail_title') end,
    'intro',            case when v_admin then _c('supplier.closed_admin_intro')
                             else _c('supplier.avail_intro') end,
    'close_button',     case when v_admin then _c('supplier.closed_admin_close_btn')
                             else _c('supplier.avail_close_btn') end,
    'reopen_button',    case when v_admin then _c('supplier.closed_admin_reopen_btn')
                             else _c('supplier.avail_reopen_btn') end,
    'reason_hint',      _c('supplier.avail_reason_hint'),
    'until_hint',       _c('supplier.avail_until_hint'),
    'until_open_label', _c('supplier.closed_until_reopen'),
    'until_pick_label', _c('supplier.closed_until_pick'),
    'until_clear_label',_c('supplier.closed_until_clear'),
    'history_title',    case when v_admin then _c('supplier.closed_admin_history_title')
                             else _c('supplier.avail_history_title') end,
    'history_empty',    _c('supplier.closed_history_none'),
    'history', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', c.id,
               'label', to_char(c.starts_at at time zone 'Asia/Kolkata', 'DD Mon')
                        || ' – '
                        || coalesce(to_char(coalesce(c.ends_at, c.reopened_at)
                                              at time zone 'Asia/Kolkata', 'DD Mon'),
                                    _c('supplier.closed_until_reopen')),
               'reason', c.reason,
               'reason_label', case when coalesce(btrim(c.reason), '') = '' then null
                                    else _cf('supplier.closed_reason',
                                             jsonb_build_object('reason', c.reason)) end,
               'by', c.closed_by,
               -- Who shut the shop is a fact the office needs on the admin
               -- panel (was it us or him?) and it is rendered here, once.
               'by_label', case when c.closed_by = 'admin'
                                then _c('supplier.closed_by_admin')
                                else _c('supplier.closed_by_supplier') end)
             order by c.starts_at desc)
      from supplier_closure c
      where lower(btrim(c.supplier_name)) = lower(v_name)
        and c.starts_at > now() - interval '90 days'), '[]'::jsonb));
end $$;

-- The supplier's own screen is now this builder with audience='supplier'. The
-- payload keeps every key #401's screen already reads and gains the new ones.
create or replace function public.supplier_availability_get()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare v_name text;
begin
  select supplier_name into v_name from supplier_profiles where id = public.my_supplier_id();
  if v_name is null then return jsonb_build_object('error', 'not_supplier'); end if;
  return public._supplier_closure_panel(v_name, 'supplier');
end $$;

-- ── the admin panel ──────────────────────────────────────────────────────────
create or replace function public.admin_supplier_closure_panel(p_supplier text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
begin
  if get_my_role() not in ('admin', 'super_admin') then
    return jsonb_build_object('error', 'not_authorized');
  end if;
  return public._supplier_closure_panel(p_supplier, 'admin');
end $$;

-- The list pill for the supplier table. ONE call for the whole visible list —
-- a per-row RPC on a 200-supplier table is the kind of N+1 the 1 GB instance
-- feels. Passing no names returns only the shops that are actually shut.
create or replace function public.admin_supplier_closure_states(p_suppliers text[] default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare v_names text[]; v_out jsonb;
begin
  if get_my_role() not in ('admin', 'super_admin') then
    return jsonb_build_object('error', 'not_authorized');
  end if;

  if p_suppliers is null then
    select array_agg(distinct btrim(c.supplier_name)) into v_names
    from supplier_closure c
    where c.reopened_at is null and c.starts_at <= now()
      and (c.ends_at is null or c.ends_at > now());
  else
    select array_agg(distinct btrim(n)) into v_names
    from unnest(p_suppliers) n where btrim(coalesce(n, '')) <> '';
  end if;

  if v_names is null or array_length(v_names, 1) is null then
    return jsonb_build_object('ok', true, 'states', '[]'::jsonb);
  end if;

  select coalesce(jsonb_agg(s order by s->>'supplier_name'), '[]'::jsonb) into v_out
  from (
    select public._supplier_closure_panel(n, 'admin')
           - 'history' - 'intro' - 'reason_hint' - 'until_hint' as s
    from unnest(v_names) n
  ) t;

  return jsonb_build_object('ok', true, 'states', v_out);
end $$;

-- ── copy ─────────────────────────────────────────────────────────────────────
-- `on conflict do update` on purpose: these are OURS (new in #435), so a
-- re-applied migration must land the current wording, not silently keep a
-- half-written earlier one.
insert into ui_copy (key, value) values
  ('supplier.closed_chip_open',          to_jsonb('Availability'::text)),
  ('supplier.closed_chip_closed',        to_jsonb('Closed'::text)),
  ('supplier.closed_admin_title',        to_jsonb('Shop availability — {supplier}'::text)),
  ('supplier.closed_admin_intro',        to_jsonb('Closing a shop stops every inquiry reaching it until it reopens. The supplier keeps his place in the ranked list and takes no missed-response mark while he is shut.'::text)),
  ('supplier.closed_admin_close_btn',    to_jsonb('Mark this shop closed'::text)),
  ('supplier.closed_admin_reopen_btn',   to_jsonb('Reopen this shop'::text)),
  ('supplier.closed_admin_history_title',to_jsonb('Closures in the last 90 days'::text)),
  ('supplier.closed_by_admin',           to_jsonb('Closed by the office'::text)),
  ('supplier.closed_by_supplier',        to_jsonb('Closed by the supplier'::text)),
  ('supplier.closed_until_pick',         to_jsonb('Pick a reopening date and time'::text)),
  ('supplier.closed_until_clear',        to_jsonb('Clear'::text)),
  ('supplier.closed_retry',              to_jsonb('Try again'::text))
on conflict (key) do update set value = excluded.value;

-- ── chip colours: data, not code ─────────────────────────────────────────────
-- Muted state colours from the design system: warning for a shut shop, neutral
-- for an open one. Recolouring is an UPDATE to this row.
update app_settings
   set value = coalesce(value, '{}'::jsonb) || jsonb_build_object('supplier_closure',
         jsonb_build_object(
           'closed',   jsonb_build_object('label', 'Closed', 'bg', '#FEF3C7', 'fg', '#92400E', 'border', '#FDE68A'),
           'open',     jsonb_build_object('label', 'Availability', 'bg', '#FFFFFF', 'fg', '#374151', 'border', '#D1D5DB'),
           '_default', jsonb_build_object('label', 'Availability', 'bg', '#FFFFFF', 'fg', '#374151', 'border', '#D1D5DB')))
 where key = 'order_status_chips';

insert into app_settings (key, value)
select 'order_status_chips', jsonb_build_object('supplier_closure',
         jsonb_build_object(
           'closed',   jsonb_build_object('label', 'Closed', 'bg', '#FEF3C7', 'fg', '#92400E', 'border', '#FDE68A'),
           'open',     jsonb_build_object('label', 'Availability', 'bg', '#FFFFFF', 'fg', '#374151', 'border', '#D1D5DB'),
           '_default', jsonb_build_object('label', 'Availability', 'bg', '#FFFFFF', 'fg', '#374151', 'border', '#D1D5DB')))
where not exists (select 1 from app_settings where key = 'order_status_chips');

-- ── grants: a SECURITY DEFINER function is a public endpoint until revoked ───
-- (#394/#422/#436 lesson — revoke from public+anon FIRST, then grant the exact
-- roles. These three read and write supplier state and must never be anon.)
revoke execute on function public._supplier_closure_panel(text, text) from public, anon;
revoke execute on function public.admin_supplier_closure_panel(text) from public, anon;
revoke execute on function public.admin_supplier_closure_states(text[]) from public, anon;
revoke execute on function public.supplier_availability_get() from public, anon;

grant execute on function public._supplier_closure_panel(text, text) to authenticated, service_role;
grant execute on function public.admin_supplier_closure_panel(text) to authenticated;
grant execute on function public.admin_supplier_closure_states(text[]) to authenticated;
grant execute on function public.supplier_availability_get() to authenticated;
