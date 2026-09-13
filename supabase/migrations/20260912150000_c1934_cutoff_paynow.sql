-- replay-target: production
-- CMD #1934 — the one clause of the cut-off rule CMD #1847 did not build:
--
--   "A warning whose time has already passed when the order is placed is
--    SKIPPED, not sent late; in its place send ONE immediate 'pay now to keep
--    this order' message with the UPI link."
--
-- #1847's order_cutoff_tick() fires a warning whenever now() is inside
-- [cutoff - warnN_min, cutoff), which is true for an order placed after that
-- instant too — so an order placed at 11:50 against a 12:00 cut-off collected
-- the 120-minute warning at 11:50 and the 30-minute warning a minute later.
-- Two late warnings, which is exactly what the spec forbids.
--
-- The decision is taken ONCE, when the order joins the clock, and it is taken
-- HERE rather than inside the tick: order_cutoff_run is written by exactly one
-- statement (the tick's insert), a BEFORE INSERT trigger sees the same row the
-- tick is about to write, and #1847's 130-line tick is left untouched — no
-- second cancel path, no copy of a function another command may have replaced.
--
-- The message itself is the SAME editable text as the warning
-- (order_alert_config.cutoff_warn_text, already carrying {{pay_link}}), so the
-- wording stays one value in the app instead of two that can drift apart. Its
-- routing is its own wa_event_routes row, so throttling, the template and the
-- push title are per-event and app-controlled like every other event.

-- ── 1. What the clock remembers about a skip ─────────────────────────────────
alter table public.order_cutoff_run
  add column if not exists warn1_skipped boolean not null default false,
  add column if not exists warn2_skipped boolean not null default false,
  add column if not exists paynow_at     timestamptz;

-- ── 2. The route for the one immediate message ───────────────────────────────
insert into public.wa_event_routes(event_key, label, description, template_name,
       language, variable_map, enabled, audience, push_enabled, email_enabled,
       push_title, auto_manage, dedupe_minutes, marketing_guard)
select 'order_cutoff_pay_now',
       'Pay now — placed after the reminders',
       'CMD #1934 — the single immediate reminder sent in place of warnings whose time had already passed when the order was placed.',
       'order_cutoff_pay_now', 'en',
       '["{{customer}}", "{{order_code}}", "{{amount}}", "{{cutoff}}", "{{pay_link}}"]'::jsonb,
       true, 'customer', true, false, 'Advance pending', true, 0, false
where not exists (select 1 from public.wa_event_routes where event_key = 'order_cutoff_pay_now');

-- ── 3. Words, on the row that already holds this screen's words ──────────────
update public.order_alert_config
   set labels = coalesce(labels, '{}'::jsonb) || jsonb_build_object(
     'cutoff_audit_order_cutoff_pay_now', 'Placed late — one pay-now message',
     'cutoff_skip_note',                  'Placed after a reminder was due — that reminder was skipped and one pay-now message was sent instead.')
 where id = 'singleton';

-- ── 4. The decision, taken once, as the order joins the clock ────────────────
create or replace function public._order_cutoff_skip_warnings()
returns trigger language plpgsql security definer set search_path = public as $$
declare cfg public.order_alert_config; o public.orders%rowtype;
        v_eff timestamptz; v_placed timestamptz; v_adv jsonb; v_vars jsonb;
        v_name text; v_s1 boolean; v_s2 boolean;
begin
  cfg := public._oa_cfg();
  select * into o from public.orders where id = new.order_id;
  if o.id is null then return new; end if;

  v_placed := coalesce(o.created_at, now());
  v_eff    := public._order_cutoff_effective(new.cutoff_at, new.extra_min);

  -- A warning whose moment was already behind the order when the order was
  -- placed can only ever be sent late, so it is spent here and never fires.
  v_s1 := v_placed >= v_eff - make_interval(mins => greatest(coalesce(cfg.cutoff_warn1_min,0),0));
  v_s2 := v_placed >= v_eff - make_interval(mins => greatest(coalesce(cfg.cutoff_warn2_min,0),0));
  if not (v_s1 or v_s2) then
    return new;
  end if;

  new.warn1_skipped := v_s1;
  new.warn2_skipped := v_s2;
  if v_s1 then new.warn1_at := now(); end if;
  if v_s2 then new.warn2_at := now(); end if;

  -- Nothing to chase: the advance is in, the admin has already accepted it, or
  -- this pharmacy is never auto-cancelled. The warnings stay spent either way.
  v_adv := public._order_advance_state(new.order_id);
  if coalesce(o.status,'') = 'accepted'
     or coalesce((v_adv->>'ok')::boolean, false)
     or public._order_cutoff_exempt(new.order_id) then
    return new;
  end if;

  select coalesce(nullif(btrim(pp.pharmacy_name),''), nullif(btrim(pp.customer_name),''), '')
    into v_name from public.pharmacy_profiles pp where pp.id = o.customer_id;

  v_vars := jsonb_build_object(
    'customer',    coalesce(v_name,''),
    'order_code',  coalesce(o.order_code,''),
    'amount',      v_adv->>'due_display',
    'cutoff',      to_char(v_eff at time zone 'Asia/Kolkata','FMHH12:MI AM'),
    'pay_link',    public._order_cutoff_pay_link(new.order_id, (v_adv->>'due')::numeric),
    'order_id',    new.order_id::text,
    'customer_id', coalesce(o.customer_id::text,''));

  -- ONE message, through the switchboard the warnings already ride. A dead
  -- notify must never keep an order off the clock, which is why #1847 swallows
  -- it at both warning sites and this does the same.
  begin
    perform public.notify('order_cutoff_pay_now', null,
      v_vars || jsonb_build_object('message',
        public.notif_render(coalesce(cfg.cutoff_warn_text,''), v_vars)));
  exception when others then null; end;
  new.paynow_at := now();

  begin
    perform public.audit_write('order_cutoff_pay_now','order', new.order_id::text, null,
      jsonb_build_object('warn1_skipped', v_s1, 'warn2_skipped', v_s2,
                         'placed_at', to_char(v_placed at time zone 'Asia/Kolkata','DD/MM HH24:MI'),
                         'cutoff_at',  to_char(v_eff   at time zone 'Asia/Kolkata','DD/MM HH24:MI'),
                         'reason', 'warning_time_passed'));
  exception when others then null; end;

  return new;
end $$;

drop trigger if exists order_cutoff_skip_warnings_trg on public.order_cutoff_run;
create trigger order_cutoff_skip_warnings_trg
  before insert on public.order_cutoff_run
  for each row execute function public._order_cutoff_skip_warnings();

revoke all on function public._order_cutoff_skip_warnings() from public, anon;

comment on function public._order_cutoff_skip_warnings() is
  'CMD #1934 — spends a cut-off warning whose time had already passed when the order was placed and sends ONE immediate pay-now message in its place.';
