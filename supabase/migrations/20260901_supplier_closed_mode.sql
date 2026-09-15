-- cmd #401 (1/3) — CLOSED / HOLIDAY MODE.
--
-- A supplier who is shut today is not a supplier who ignored us. Until now the
-- waterfall could not tell the two apart: it asked him anyway, waited the full
-- ten minutes, and then `sweep_inquiry_timeouts` wrote 'No response' into his
-- answer slot and logged it against him. That is a timeout penalty and ranking
-- damage for being closed on a Sunday.
--
-- THE CENTRAL DESIGN CHOICE, and the reason "reopening restores him
-- automatically" needs no restore code: a closed supplier is SKIPPED, never
-- ANSWERED. His PS slot keeps its place in the ranked list and his AS slot
-- stays NULL, so there is no state to undo — the moment the closure window
-- ends he is simply eligible again, in the same position he always held. Any
-- design that wrote a 'Closed' answer would have to find and erase it later,
-- and would have handed the same row two different truths.
--
-- Closures are logged rather than toggled for the same reason: `closed_until`
-- as a column on supplier_profiles would answer "is he shut now?" and nothing
-- else. A log answers "how often is he shut?", which is what makes chronic
-- closure visible in his stats.

create table if not exists supplier_closure (
  id           bigserial primary key,
  supplier_name text        not null,
  starts_at    timestamptz not null default now(),
  -- NULL means "closed until he reopens" — an open-ended holiday is a real
  -- case (a shop shut for a funeral does not know the end date yet).
  ends_at      timestamptz,
  reason       text,
  closed_by    text not null default 'supplier',   -- supplier | admin
  reopened_at  timestamptz,
  created_at   timestamptz not null default now()
);
create index if not exists supplier_closure_active_idx
  on supplier_closure (lower(btrim(supplier_name)), starts_at desc);

-- Is this supplier shut RIGHT NOW? One definition, used by the waterfall, the
-- admin card and the supplier's own screen, so the three can never disagree.
create or replace function public.supplier_closed_now(p_supplier text)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select exists (
    select 1 from supplier_closure c
     where lower(btrim(c.supplier_name)) = lower(btrim(coalesce(p_supplier,'')))
       and c.reopened_at is null
       and c.starts_at <= now()
       and (c.ends_at is null or c.ends_at > now())
  );
$$;

-- The one active closure, rendered. Every string here, never in Dart.
create or replace function public.supplier_closure_state(p_supplier text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare c supplier_closure%rowtype; v_until text; v_closures int; v_days numeric;
begin
  select * into c from supplier_closure
   where lower(btrim(supplier_name)) = lower(btrim(coalesce(p_supplier,'')))
     and reopened_at is null and starts_at <= now()
     and (ends_at is null or ends_at > now())
   order by starts_at desc limit 1;

  -- Chronic closure is a 90-day fact, not a today fact.
  select count(*), coalesce(sum(extract(epoch from (coalesce(least(ends_at, now()), coalesce(reopened_at, now())) - starts_at)) / 86400), 0)
    into v_closures, v_days
  from supplier_closure
   where lower(btrim(supplier_name)) = lower(btrim(coalesce(p_supplier,'')))
     and starts_at > now() - interval '90 days';

  if c.id is null then
    return jsonb_build_object(
      'closed', false,
      'status_label', _c('supplier.closed_open_label'),
      'status_tone', 'success',
      'closures_90d', v_closures,
      'closed_days_90d', round(v_days),
      'history_label', case when v_closures = 0 then _c('supplier.closed_history_none')
                            else _cf('supplier.closed_history',
                                   jsonb_build_object('n', v_closures::text,
                                                      'days', trim(to_char(round(v_days),'FM999')))) end);
  end if;

  v_until := case when c.ends_at is null then _c('supplier.closed_until_reopen')
                  else to_char(c.ends_at at time zone 'Asia/Kolkata', 'DD Mon, HH12:MI AM') end;
  return jsonb_build_object(
    'closed', true,
    'closure_id', c.id,
    'reason', c.reason,
    'ends_at', c.ends_at,
    'status_label', _cf('supplier.closed_label', jsonb_build_object('until', v_until)),
    'status_tone', 'warning',
    'reason_label', case when coalesce(btrim(c.reason),'') = '' then null
                         else _cf('supplier.closed_reason', jsonb_build_object('reason', c.reason)) end,
    'closures_90d', v_closures,
    'closed_days_90d', round(v_days),
    'history_label', _cf('supplier.closed_history',
                       jsonb_build_object('n', v_closures::text,
                                          'days', trim(to_char(round(v_days),'FM999')))));
end $$;

-- When a supplier closes while an inquiry is sitting on him, move that inquiry
-- on NOW and write NOTHING into his answer slot. Waiting for the ten-minute
-- timeout would cost the customer ten minutes AND cost him a 'No response'.
-- WHERE THE SKIP ACTUALLY LIVES.
--
-- `inquiry.current_supplier` is not a column you set — it is DERIVED. The
-- BEFORE INSERT OR UPDATE trigger `t2_current_supplier_trg` recomputes it from
-- the PS/AS slots on every single write, so the first version of this change
-- (which computed a new current_supplier and UPDATEd it) reported "46 inquiries
-- moved" while all 46 rows still pointed at the shop that had just closed: the
-- trigger recomputed the same answer straight back over it.
--
-- So the skip goes in the trigger, next to the `status ILIKE 'active'` check
-- that is already there for exactly this purpose — one authority deciding who
-- is next, not two disagreeing. Everything else follows for free: any write to
-- the row re-derives the right supplier, and reopening needs no restore logic
-- because the AS slots were never written.
create or replace function public.compute_current_supplier_fx()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
DECLARE
  i int; ps_val text; as_val text; v_canon text; found int := 0; v_mode text;
BEGIN
  IF NEW.inquiry_phase = 'sent' THEN RETURN NEW; END IF;

  SELECT value #>> '{}' INTO v_mode FROM app_settings WHERE key = 'allocation_mode';
  v_mode := COALESCE(v_mode, 'first_available');

  IF v_mode = 'fewest_baskets' AND NEW.manual_supplier IS NOT NULL AND btrim(NEW.manual_supplier) <> '' THEN
    SELECT sp.supplier_name INTO v_canon
    FROM supplier_profiles sp
    WHERE lower(btrim(sp.supplier_name)) = lower(btrim(NEW.manual_supplier))
      AND sp.status ILIKE 'active'
    ORDER BY sp."SPN" DESC NULLS LAST LIMIT 1;
    IF v_canon IS NOT NULL THEN
      NEW.current_supplier := v_canon;
      NEW.next_supplier := NULL;
      RETURN NEW;
    END IF;
  END IF;

  IF v_mode = 'fewest_baskets' AND TG_OP = 'UPDATE' THEN
    RETURN NEW;
  END IF;

  NEW.current_supplier := NULL;
  NEW.next_supplier    := NULL;
  FOR i IN 1..30 LOOP
    EXECUTE format('SELECT ($1).%I, ($1).%I','PS'||i,'AS'||i) INTO ps_val, as_val USING NEW;
    IF ps_val IS NULL OR btrim(ps_val) = '' THEN EXIT; END IF;

    SELECT sp.supplier_name INTO v_canon
    FROM supplier_profiles sp
    WHERE lower(btrim(sp.supplier_name)) = lower(btrim(ps_val))
      AND sp.status ILIKE 'active'
    ORDER BY sp."SPN" DESC NULLS LAST LIMIT 1;

    IF v_canon IS NULL THEN CONTINUE; END IF;
    -- cmd #401: a shut shop is passed over exactly like an inactive one. His
    -- slot and his (empty) answer are left alone, so when the closure ends the
    -- next write to this row puts him back in the same position.
    IF public.supplier_closed_now(v_canon) THEN CONTINUE; END IF;

    IF as_val IS NULL OR btrim(as_val) = '' OR as_val = 'Available' THEN
      found := found + 1;
      IF found = 1 THEN
        NEW.current_supplier := v_canon;
      ELSIF found = 2 THEN
        NEW.next_supplier := v_canon;
        EXIT;
      END IF;
    END IF;
  END LOOP;

  RETURN NEW;
END;
$function$;

-- The nudge. The trigger only fires on a write, so a closure (or a reopening)
-- has to touch the rows whose answer it changes. Rows frozen at
-- inquiry_phase='sent' are the one case the trigger opts out of, so those go
-- back to 'draft' first: a shop that is shut is not a shop we are still waiting
-- on, and leaving the row 'sent' is exactly what would earn him the
-- 'No response' this feature exists to prevent.
create or replace function public._inquiry_advance_past_closed(p_supplier text)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare v_moved int := 0;
begin
  if coalesce(btrim(p_supplier),'') = '' then return 0; end if;

  update inquiry
     set inquiry_phase = 'draft', asked_at = null
   where lower(btrim(coalesce(current_supplier,''))) = lower(btrim(p_supplier))
     and coalesce(inquiry_phase,'draft') = 'sent';

  -- Writing the column back to itself is what makes the trigger re-derive it,
  -- and the trigger now knows he is closed.
  update inquiry
     set current_supplier = current_supplier
   where lower(btrim(coalesce(current_supplier,''))) = lower(btrim(p_supplier));
  get diagnostics v_moved = row_count;

  delete from inquiry_forms
   where lower(btrim(supplier_name)) = lower(btrim(p_supplier))
     and status not in ('responded','partially_responded');

  return v_moved;
end $fn$;

-- Reopening is the same nudge in reverse: touch every row where he still holds
-- a slot the trigger would accept, and it puts him back at his own rank.
--
-- The eligibility test here MUST be the trigger's, not a stricter one. The
-- first version matched only an EMPTY answer slot and restored 14 of 46
-- inquiries: 31 of his slots read 'Available', which the trigger treats as
-- eligible and this function did not, so those rows stayed parked on the
-- supplier they had been handed to. Two definitions of "eligible" in two places
-- is the same class of bug as two definitions of "current supplier".
create or replace function public._inquiry_readmit_supplier(p_supplier text)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare v_n int := 0; i int;
begin
  if coalesce(btrim(p_supplier),'') = '' then return 0; end if;
  for i in 1..30 loop
    execute format(
      'update inquiry set current_supplier = current_supplier
         where lower(btrim(coalesce(%1$I,''''))) = lower(btrim($1))
           and (%2$I is null or btrim(%2$I) = '''' or %2$I = ''Available'')
           and coalesce(inquiry_phase,''draft'') <> ''sent''',
      'PS'||i, 'AS'||i) using p_supplier;
  end loop;
  select count(*) into v_n from inquiry
   where lower(btrim(coalesce(current_supplier,''))) = lower(btrim(p_supplier));
  return v_n;
end $fn$;

-- ── write side ──────────────────────────────────────────────────────────────
create or replace function public._supplier_close(p_supplier text, p_until timestamptz,
                                                  p_reason text, p_by text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_id bigint; v_moved int;
begin
  if coalesce(btrim(p_supplier),'') = '' then return jsonb_build_object('error','no_supplier'); end if;
  if p_until is not null and p_until <= now() then
    return jsonb_build_object('error','bad_range', 'message', _c('supplier.closed_bad_range'));
  end if;

  -- Closing while already closed REPLACES the window rather than stacking a
  -- second one, so "closed until" is never two answers at once.
  update supplier_closure set reopened_at = now()
   where lower(btrim(supplier_name)) = lower(btrim(p_supplier))
     and reopened_at is null and (ends_at is null or ends_at > now());

  insert into supplier_closure (supplier_name, starts_at, ends_at, reason, closed_by)
  values (btrim(p_supplier), now(), p_until, nullif(btrim(coalesce(p_reason,'')),''), coalesce(p_by,'supplier'))
  returning id into v_id;

  v_moved := public._inquiry_advance_past_closed(p_supplier);

  return jsonb_build_object('ok', true, 'closure_id', v_id, 'inquiries_moved', v_moved,
                            'state', public.supplier_closure_state(p_supplier),
                            'message', _c('supplier.closed_toast'));
end $$;

create or replace function public._supplier_reopen(p_supplier text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  update supplier_closure set reopened_at = now()
   where lower(btrim(supplier_name)) = lower(btrim(coalesce(p_supplier,'')))
     and reopened_at is null and (ends_at is null or ends_at > now());
  -- Nothing to UNDO: his PS slots never moved and his AS slots were never
  -- written. All that is needed is a write on those rows so the trigger
  -- re-derives with him eligible again.
  perform public._inquiry_readmit_supplier(p_supplier);
  return jsonb_build_object('ok', true,
                            'state', public.supplier_closure_state(p_supplier),
                            'message', _c('supplier.reopen_toast'));
end $$;

-- The supplier's own controls — scoped to my_supplier_id(), never a name from
-- the client.
create or replace function public.supplier_close_shop(p_until timestamptz default null,
                                                      p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_name text;
begin
  select supplier_name into v_name from supplier_profiles where id = public.my_supplier_id();
  if v_name is null then return jsonb_build_object('error','not_supplier'); end if;
  return public._supplier_close(v_name, p_until, p_reason, 'supplier');
end $$;

create or replace function public.supplier_reopen_shop()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_name text;
begin
  select supplier_name into v_name from supplier_profiles where id = public.my_supplier_id();
  if v_name is null then return jsonb_build_object('error','not_supplier'); end if;
  return public._supplier_reopen(v_name);
end $$;

create or replace function public.admin_supplier_set_closed(p_supplier text, p_closed boolean,
                                                            p_until timestamptz default null,
                                                            p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('error','not_authorized');
  end if;
  if p_closed then return public._supplier_close(p_supplier, p_until, p_reason, 'admin');
  else return public._supplier_reopen(p_supplier); end if;
end $$;

-- ── the supplier's Availability screen, one rendered payload ────────────────
create or replace function public.supplier_availability_get()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare v_name text; v_state jsonb;
begin
  select supplier_name into v_name from supplier_profiles where id = public.my_supplier_id();
  if v_name is null then return jsonb_build_object('error','not_supplier'); end if;
  v_state := public.supplier_closure_state(v_name);
  return v_state || jsonb_build_object(
    'ok', true,
    'supplier_name', v_name,
    'screen_title', _c('supplier.avail_title'),
    'intro', _c('supplier.avail_intro'),
    'close_button', _c('supplier.avail_close_btn'),
    'reopen_button', _c('supplier.avail_reopen_btn'),
    'reason_hint', _c('supplier.avail_reason_hint'),
    'until_hint', _c('supplier.avail_until_hint'),
    'until_open_label', _c('supplier.closed_until_reopen'),
    'history_title', _c('supplier.avail_history_title'),
    'history', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', c.id,
               'label', to_char(c.starts_at at time zone 'Asia/Kolkata','DD Mon')
                        || ' – '
                        || coalesce(to_char(coalesce(c.ends_at, c.reopened_at) at time zone 'Asia/Kolkata','DD Mon'),
                                    _c('supplier.closed_until_reopen')),
               'reason', c.reason,
               'by', c.closed_by)
             order by c.starts_at desc)
      from supplier_closure c
      where lower(btrim(c.supplier_name)) = lower(btrim(v_name))
        and c.starts_at > now() - interval '90 days'), '[]'::jsonb));
end $$;

-- ── waterfall: skip the closed, never penalise them ─────────────────────────
-- The ONLY change to the sweep is the two eligibility tests. A supplier who is
-- closed is passed over silently; a supplier who is closed AND currently being
-- waited on has his wait ended without an answer being written.
create or replace function public.sweep_inquiry_timeouts()
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
DECLARE
  v_id bigint; r_inq inquiry%ROWTYPE; i int;
  ps_val text; as_val text; slot_n int;
  new_current text; new_next text; found_ct int;
  v_ps text; v_as text; v_old_sup text;
BEGIN
  IF public.inquiry_any_locked() THEN
    -- cmd #401: a supplier who closed while we were waiting on him is moved on
    -- immediately, with no answer written and therefore no penalty.
    FOR v_old_sup IN
      SELECT DISTINCT i2.current_supplier FROM inquiry i2
       WHERE i2.current_supplier IS NOT NULL
         AND public.supplier_closed_now(i2.current_supplier)
    LOOP
      PERFORM public._inquiry_advance_past_closed(v_old_sup);
    END LOOP;

    FOR v_id IN
      SELECT inquiry.id FROM inquiry
      WHERE inquiry.current_supplier IS NOT NULL
        AND inquiry.asked_at IS NOT NULL
        AND inquiry.asked_at < now() - interval '10 minutes'
    LOOP
      SELECT * INTO r_inq FROM inquiry WHERE inquiry.id = v_id;
      v_old_sup := r_inq.current_supplier;
      -- Belt and braces: never write 'No response' against a closed shop.
      CONTINUE WHEN public.supplier_closed_now(v_old_sup);
      slot_n := NULL; as_val := NULL;
      FOR i IN 1..30 LOOP
        EXECUTE format('SELECT ($1).%I, ($1).%I','PS'||i,'AS'||i) INTO ps_val, as_val USING r_inq;
        IF ps_val = r_inq.current_supplier THEN slot_n := i; EXIT; END IF;
        as_val := NULL;
      END LOOP;
      IF slot_n IS NOT NULL AND as_val IS NULL THEN
        EXECUTE format('UPDATE inquiry SET %I = $1 WHERE inquiry.id = $2','AS'||slot_n)
          USING 'No response', v_id;
        PERFORM public.inquiry_log_answer(v_old_sup, r_inq.product_id, 'No response');
        SELECT * INTO r_inq FROM inquiry WHERE inquiry.id = v_id;
        new_current := NULL; new_next := NULL; found_ct := 0;
        FOR i IN 1..30 LOOP
          EXECUTE format('SELECT ($1).%I, ($1).%I','PS'||i,'AS'||i) INTO v_ps, v_as USING r_inq;
          IF v_ps IS NULL OR btrim(v_ps) = '' THEN EXIT; END IF;
          IF (v_as IS NULL OR btrim(v_as) = '' OR v_as = 'Available')
             AND NOT public.supplier_closed_now(v_ps) THEN
            found_ct := found_ct + 1;
            IF found_ct = 1 THEN new_current := v_ps;
            ELSIF found_ct = 2 THEN new_next := v_ps; EXIT; END IF;
          END IF;
        END LOOP;
        UPDATE inquiry SET current_supplier = new_current, next_supplier = new_next,
               asked_at = CASE WHEN new_current IS NOT NULL THEN now() ELSE inquiry.asked_at END
        WHERE inquiry.id = v_id;
        IF new_current IS NOT NULL THEN
          INSERT INTO inquiry_forms (supplier_name, last_sent_at, expires_at, status)
          VALUES (new_current, now(), now() + interval '10 minutes','pending')
          ON CONFLICT ON CONSTRAINT inquiry_forms_supplier_name_key DO UPDATE SET
            last_sent_at = now(), expires_at = now() + interval '10 minutes', status = 'pending';
        END IF;
      END IF;
    END LOOP;
  END IF;

  DELETE FROM inquiry_forms
   WHERE status NOT IN ('responded','partially_responded')
     AND expires_at IS NOT NULL AND expires_at < now();
  DELETE FROM inquiry_forms f
   WHERE f.status NOT IN ('responded','partially_responded')
     AND NOT EXISTS (SELECT 1 FROM inquiry i WHERE i.current_supplier = f.supplier_name);
END;
$function$;

-- A send must not reach a closed shop either — the sweep is not the only door.
create or replace function public.start_inquiry_for_suppliers(p_supplier_names text[] DEFAULT NULL::text[], p_force boolean DEFAULT false)
returns TABLE(supplier_name text, token text, status text, expires_at timestamptz)
language plpgsql
security definer
set search_path to 'public'
as $function$
DECLARE
  v_suppliers text[]; v_sup text; v_token text; v_status text;
  v_expires timestamptz; v_ready jsonb; v_started boolean;
BEGIN
  v_ready := public.inquiry_send_readiness();
  IF NOT (v_ready->>'can_send')::boolean THEN
    IF p_force AND get_my_role() = 'super_admin' THEN NULL;
    ELSE RAISE EXCEPTION 'inquiry_send_blocked' USING HINT = v_ready::text; END IF;
  END IF;

  v_started := public.inquiry_locked();

  IF p_supplier_names IS NULL THEN
    SELECT ARRAY_AGG(DISTINCT sup) INTO v_suppliers
    FROM ( SELECT i.current_supplier AS sup FROM inquiry i WHERE i.current_supplier IS NOT NULL
           UNION
           SELECT i.next_supplier AS sup FROM inquiry i WHERE i.next_supplier IS NOT NULL ) t;
  ELSE
    v_suppliers := p_supplier_names;
  END IF;
  IF v_suppliers IS NULL OR array_length(v_suppliers, 1) = 0 THEN RETURN; END IF;

  FOREACH v_sup IN ARRAY v_suppliers LOOP
    -- cmd #401: a closed shop is skipped here, and the inquiries pointed at him
    -- are advanced rather than left to time out against him.
    IF public.supplier_closed_now(v_sup) THEN
      PERFORM public._inquiry_advance_past_closed(v_sup);
      RETURN QUERY SELECT v_sup, NULL::text, 'closed'::text, NULL::timestamptz;
      CONTINUE;
    END IF;

    IF v_started THEN
      INSERT INTO inquiry_forms (supplier_name, last_sent_at, expires_at, status)
      VALUES (v_sup, now(), now() + interval '10 minutes', 'pending')
      ON CONFLICT ON CONSTRAINT inquiry_forms_supplier_name_key DO UPDATE SET
        last_sent_at = now(), expires_at = now() + interval '10 minutes',
        status = CASE WHEN inquiry_forms.status IN ('expired','draft') THEN 'pending' ELSE inquiry_forms.status END;
      UPDATE inquiry SET asked_at = COALESCE(asked_at, now()),
                         inquiry_phase = 'sent'
       WHERE (current_supplier = v_sup OR next_supplier = v_sup)
         AND coalesce(inquiry_phase,'draft') IN ('draft','sent');
    ELSE
      INSERT INTO inquiry_forms (supplier_name, last_sent_at, expires_at, status)
      VALUES (v_sup, now(), NULL, 'draft')
      ON CONFLICT ON CONSTRAINT inquiry_forms_supplier_name_key DO UPDATE SET
        last_sent_at = now(), expires_at = NULL,
        status = CASE WHEN inquiry_forms.status IN ('pending','expired') THEN 'draft' ELSE inquiry_forms.status END;
      UPDATE inquiry SET asked_at = NULL,
                         inquiry_phase = 'draft'
       WHERE (current_supplier = v_sup OR next_supplier = v_sup)
         AND coalesce(inquiry_phase,'draft') IN ('draft','sent');
    END IF;

    SELECT f.token, f.status, f.expires_at INTO v_token, v_status, v_expires
    FROM inquiry_forms f WHERE f.supplier_name = v_sup;
    RETURN QUERY SELECT v_sup, v_token, v_status, v_expires;
  END LOOP;
END;
$function$;

-- ── copy ────────────────────────────────────────────────────────────────────
insert into ui_copy (key, value) values
  ('supplier.avail_title',         to_jsonb('Shop availability'::text)),
  ('supplier.avail_intro',         to_jsonb('Mark your shop closed and we will stop sending you inquiries until you reopen. Being closed costs you nothing — no missed-response mark, no drop in your ranking.'::text)),
  ('supplier.avail_close_btn',     to_jsonb('Mark shop closed'::text)),
  ('supplier.avail_reopen_btn',    to_jsonb('Reopen the shop'::text)),
  ('supplier.avail_reason_hint',   to_jsonb('Reason (optional) — e.g. holiday, stock-taking'::text)),
  ('supplier.avail_until_hint',    to_jsonb('Closed until (leave blank if you do not know yet)'::text)),
  ('supplier.avail_history_title', to_jsonb('Your closures in the last 90 days'::text)),
  ('supplier.closed_open_label',   to_jsonb('Open — receiving inquiries'::text)),
  ('supplier.closed_label',        to_jsonb('Closed until {until}'::text)),
  ('supplier.closed_until_reopen', to_jsonb('you reopen'::text)),
  ('supplier.closed_reason',       to_jsonb('Reason: {reason}'::text)),
  ('supplier.closed_history',      to_jsonb('{n} closure(s), {days} day(s) shut in the last 90 days'::text)),
  ('supplier.closed_history_none', to_jsonb('No closures in the last 90 days'::text)),
  ('supplier.closed_bad_range',    to_jsonb('That reopening time is already in the past. Pick a later time, or leave it blank.'::text)),
  ('supplier.closed_toast',        to_jsonb('Shop marked closed. You will get no inquiries until you reopen.'::text)),
  ('supplier.reopen_toast',        to_jsonb('Shop reopened. You are back in the inquiry list where you were.'::text))
on conflict (key) do nothing;

-- ── grants: a SECURITY DEFINER function is a public endpoint until revoked ──
-- (supplier lesson from #394/#422 — revoke first, then grant the exact roles.)
revoke execute on function public.supplier_closed_now(text) from public, anon;
revoke execute on function public.supplier_closure_state(text) from public, anon;
revoke execute on function public._inquiry_advance_past_closed(text) from public, anon;
revoke execute on function public._inquiry_readmit_supplier(text) from public, anon;
revoke execute on function public._supplier_close(text, timestamptz, text, text) from public, anon;
revoke execute on function public._supplier_reopen(text) from public, anon;
revoke execute on function public.supplier_close_shop(timestamptz, text) from public, anon;
revoke execute on function public.supplier_reopen_shop() from public, anon;
revoke execute on function public.admin_supplier_set_closed(text, boolean, timestamptz, text) from public, anon;
revoke execute on function public.supplier_availability_get() from public, anon;

grant execute on function public.supplier_close_shop(timestamptz, text) to authenticated;
grant execute on function public.supplier_reopen_shop() to authenticated;
grant execute on function public.supplier_availability_get() to authenticated;
grant execute on function public.admin_supplier_set_closed(text, boolean, timestamptz, text) to authenticated;
grant execute on function public.supplier_closure_state(text) to authenticated, service_role;
grant execute on function public.supplier_closed_now(text) to authenticated, service_role;
