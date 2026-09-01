-- CHANGE #430 — PHARMACY STOCK AUDIT, part 2: variance, the blind second count,
-- risk-directed cycles, the sealed log and what happens next.
--
-- The first count is never the verdict. A discrepancy is a QUESTION, and the
-- answer is a second count taken BLIND by a DIFFERENT person: two counts that
-- agree are treated as truth and the ledger moves; two that disagree go to the
-- owner, who is the only one who may decide. This is why an audit is worth
-- running at all — a single count by the person responsible for the shelf is
-- exactly the count you cannot rely on.

insert into public.ui_copy(key, value) values
 ('phaudit.close_title',   to_jsonb('Variance'::text)),
 ('phaudit.close_note',    to_jsonb('Counted against what the books expected, batch by batch.'::text)),
 ('phaudit.short_label',   to_jsonb('Short'::text)),
 ('phaudit.excess_label',  to_jsonb('Extra'::text)),
 ('phaudit.match_label',   to_jsonb('Matches'::text)),
 ('phaudit.value_at_stake', to_jsonb('Value at stake'::text)),
 ('phaudit.variance_row',  to_jsonb('{{counted}} counted · {{expected}} expected'::text)),
 ('phaudit.sold_note',     to_jsonb('{{n}} sold while you were counting — already allowed for'::text)),
 ('phaudit.recount_title', to_jsonb('Second count'::text)),
 ('phaudit.recount_note',  to_jsonb('Someone else counts these, without seeing the first number.'::text)),
 ('phaudit.recount_empty', to_jsonb('Nothing needs a second count'::text)),
 ('phaudit.recount_same_person', to_jsonb('A different person has to count these.'::text)),
 ('phaudit.agreed',        to_jsonb('Both counts agree'::text)),
 ('phaudit.disagreed',     to_jsonb('The two counts disagree — the owner decides'::text)),
 ('phaudit.owner_review',  to_jsonb('Owner review'::text)),
 ('phaudit.owner_only',    to_jsonb('Only the owner can settle a disagreement.'::text)),
 ('phaudit.accept_button', to_jsonb('Accept and adjust the ledger'::text)),
 ('phaudit.accepted',      to_jsonb('Ledger adjusted on {{n}}'::text)),
 ('phaudit.accept_blocked', to_jsonb('Settle the disagreements first.'::text)),
 ('phaudit.cycle_title',   to_jsonb('Count these today'::text)),
 ('phaudit.cycle_note',    to_jsonb('The riskiest {{n}} on your shelf — least certain, most valuable.'::text)),
 ('phaudit.cycle_empty',   to_jsonb('Nothing needs counting today'::text)),
 ('phaudit.cycle_reason_conf', to_jsonb('Estimate is least certain here'::text)),
 ('phaudit.cycle_reason_value', to_jsonb('High value on the shelf'::text)),
 ('phaudit.cycle_reason_flag', to_jsonb('Went short last time'::text)),
 ('phaudit.seal_title',    to_jsonb('Sealed record'::text)),
 ('phaudit.seal_ok',       to_jsonb('Sealed and unbroken · {{n}} entries'::text)),
 ('phaudit.seal_broken',   to_jsonb('This record has been altered at entry {{seq}}'::text)),
 ('phaudit.seal_none',     to_jsonb('Nothing sealed yet'::text)),
 ('phaudit.cert_title',    to_jsonb('Stock value certificate'::text)),
 ('phaudit.cert_line',     to_jsonb('Counted stock at cost on {{date}}: {{value}}'::text)),
 ('phaudit.cert_note',     to_jsonb('Issued from a sealed physical count. Entry {{seq}}, hash {{hash}}.'::text)),
 ('phaudit.trend_title',   to_jsonb('Shrinkage trend'::text)),
 ('phaudit.trend_empty',   to_jsonb('Not enough audits yet to show a trend'::text)),
 ('phaudit.actions_title', to_jsonb('What to do next'::text)),
 ('phaudit.action_theft',  to_jsonb('{{n}} short — look at the theft radar'::text)),
 ('phaudit.action_exchange', to_jsonb('{{n}} extra and near expiry — offer them on the exchange'::text)),
 ('phaudit.action_reorder', to_jsonb('{{n}} counted zero that usually sell — add to the reorder cart'::text)),
 ('phaudit.actions_none',  to_jsonb('Nothing to chase from this count'::text)),
 ('phaudit.photo_sample',  to_jsonb('Photograph these {{n}} as proof'::text)),
 ('phaudit.n_lines_one',   to_jsonb('1 line'::text)),
 ('phaudit.n_lines_many',  to_jsonb('{{n}} lines'::text))
on conflict (key) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. CLOSE — variance, freeze-free reconciliation, and who has to count again
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._c430_sold_during(p_stock uuid, p_from timestamptz, p_to timestamptz)
returns numeric language sql stable set search_path to 'public' as $$
  select coalesce(sum(abs(m.qty_delta)), 0)
    from public.pharmacy_stock_move m
   where m.stock_id = p_stock
     and m.kind = 'sale'
     and m.created_at >= p_from
     and m.created_at <= coalesce(p_to, now());
$$;

create or replace function public.pharmacy_audit_close(p_session_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_shop uuid := public._c430_shop(); ss public.pharmacy_count_session;
  v_cfg public.pharmacy_audit_config; l record;
  v_sold numeric; v_expected numeric; v_var numeric;
  v_disc integer := 0; v_units numeric := 0; v_value numeric := 0;
  v_sample integer; v_marked integer := 0;
begin
  if v_shop is null then return public._c430_denied(); end if;
  select * into ss from public.pharmacy_count_session
   where id = p_session_id and pharmacy_id = v_shop;
  if not found then
    return jsonb_build_object('ok', false, 'error','no_session',
                              'message', public.ui_text('phaudit.err_no_session'));
  end if;
  if ss.status <> 'open' then
    return jsonb_build_object('ok', false, 'error','closed',
                              'message', public.ui_text('phaudit.err_closed'));
  end if;
  v_cfg := public._c430_cfg(v_shop);

  for l in select * from public.pharmacy_count_line where session_id = ss.id loop
    -- FREEZE-FREE. The shop kept selling while the count ran, so the target the
    -- counter is measured against moves with it: expected − what left the shelf
    -- through a till between the freeze and now. Without this every busy shop
    -- would show a phantom shortage exactly the size of its trade.
    v_sold := public._c430_sold_during(l.stock_id, ss.frozen_at, now());
    v_expected := greatest(coalesce(l.expected_qty,0) - v_sold, 0);

    if l.counted_qty is null then
      update public.pharmacy_count_line
         set expected_qty = v_expected, sold_qty = v_sold, status = 'uncounted'
       where id = l.id;
      continue;
    end if;

    v_var := l.counted_qty - v_expected;
    update public.pharmacy_count_line
       set expected_qty = v_expected, sold_qty = v_sold,
           variance_qty = v_var,
           variance_value = round(v_var * coalesce(l.unit_cost,0), 2),
           status = case when abs(v_var) <= coalesce(v_cfg.tolerance_qty,0)
                         then 'matched' else 'discrepant' end
     where id = l.id;

    if abs(v_var) > coalesce(v_cfg.tolerance_qty,0) then
      v_disc  := v_disc + 1;
      v_units := v_units + abs(v_var);
      v_value := v_value + abs(round(v_var * coalesce(l.unit_cost,0), 2));
      -- the blind second count is RAISED here, assigned to nobody yet: whoever
      -- takes it simply must not be the person who counted it the first time.
      if v_cfg.recount_required then
        insert into public.pharmacy_count_round (session_id, line_id, round_no)
        values (ss.id, l.id, 2) on conflict (line_id, round_no) do nothing;
      end if;
    end if;
  end loop;

  -- Random photo sampling: a fixed share of the COUNTED lines have to carry a
  -- picture, chosen after the count so nobody can prepare the shelf for it.
  select greatest(round(count(*) * coalesce(v_cfg.photo_sample_pct,10) / 100.0)::int, 1)
    into v_sample from public.pharmacy_count_line
   where session_id = ss.id and counted_qty is not null;

  update public.pharmacy_count_line set needs_photo = true
   where id in (select id from public.pharmacy_count_line
                 where session_id = ss.id and counted_qty is not null
                 order by random() limit v_sample);
  get diagnostics v_marked = row_count;

  update public.pharmacy_count_session
     set status = 'closed', closed_at = now(), submitted_at = now(),
         discrepant_lines = v_disc, variance_units = v_units, variance_value = v_value
   where id = ss.id;

  perform public.audit_log_append(v_shop, ss.id, 'session_closed', jsonb_build_object(
    'discrepant', v_disc, 'variance_units', v_units, 'variance_value', v_value,
    'photo_sample', v_marked));

  return jsonb_build_object('ok', true, 'session_id', ss.id,
    'discrepant', v_disc, 'variance_units', v_units,
    'variance_value_display', public.inr_money(v_value),
    'photo_sample', v_marked,
    'photo_sample_label', public.ui_fmt('phaudit.photo_sample',
       jsonb_build_object('n', v_marked::text)),
    'message', case when v_disc = 0 then public.ui_text('phaudit.recount_empty')
                    else public.ui_text('phaudit.recount_note') end);
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. THE BLIND SECOND COUNT
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.pharmacy_audit_recount_sheet(p_session_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_shop uuid := public._c430_shop(); ss public.pharmacy_count_session;
        r record; v_rows jsonb := '[]'::jsonb;
begin
  if v_shop is null then return public._c430_denied(); end if;
  select * into ss from public.pharmacy_count_session
   where id = p_session_id and pharmacy_id = v_shop;
  if not found then
    return jsonb_build_object('ok', false, 'error','no_session',
                              'message', public.ui_text('phaudit.err_no_session'));
  end if;

  for r in
    select cr.id as round_id, cl.*
      from public.pharmacy_count_round cr
      join public.pharmacy_count_line cl on cl.id = cr.line_id
     where cr.session_id = ss.id and cr.counted_qty is null
     order by cl.product_name
  loop
    -- Neither the first count nor the expected number is in this payload. The
    -- second counter is looking at the shelf, not at anybody's answer.
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'round_id',     r.round_id,
      'line_id',      r.id,
      'product_name', coalesce(r.product_name,''),
      'pack_label',   coalesce(r.pack_label,''),
      'batch_label',  case when coalesce(btrim(coalesce(r.batch_no,'')),'') = ''
                           then public.ui_text('phradar.no_batch')
                           else public.ui_fmt('phradar.batch_label',
                                  jsonb_build_object('batch', r.batch_no)) end,
      'first_counted_by', coalesce(r.counted_label, ''),
      'blocked_for_me', (r.counted_by is not distinct from auth.uid()),
      'blocked_message', case when r.counted_by is not distinct from auth.uid()
                              then public.ui_text('phaudit.recount_same_person') end));
  end loop;

  return jsonb_build_object('ok', true, 'session_id', ss.id,
    'title', public.ui_text('phaudit.recount_title'),
    'note',  public.ui_text('phaudit.recount_note'),
    'rows', v_rows,
    'empty', public.ui_text('phaudit.recount_empty'));
end $$;

create or replace function public.pharmacy_audit_recount(p_round_id uuid, p_qty numeric, p_method text default 'type')
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_shop uuid := public._c430_shop(); cr public.pharmacy_count_round;
  cl public.pharmacy_count_line; v_label text := public._c430_actor_label();
  v_agree boolean;
begin
  if v_shop is null then return public._c430_denied(); end if;
  select cr2.* into cr from public.pharmacy_count_round cr2
    join public.pharmacy_count_session s on s.id = cr2.session_id
   where cr2.id = p_round_id and s.pharmacy_id = v_shop;
  if not found then
    return jsonb_build_object('ok', false, 'error','no_round',
                              'message', public.ui_text('phaudit.err_no_line'));
  end if;
  if p_qty is null or p_qty < 0 then
    return jsonb_build_object('ok', false, 'error','bad_qty',
                              'message', public.ui_text('phaudit.err_bad_qty'));
  end if;

  select * into cl from public.pharmacy_count_line where id = cr.line_id;

  -- THE RULE THIS WHOLE FEATURE EXISTS FOR: the person who counted it first
  -- may not be the person who confirms it. Enforced here, in the database,
  -- where no client can route around it.
  if cl.counted_by is not distinct from auth.uid() then
    return jsonb_build_object('ok', false, 'error','same_person',
                              'message', public.ui_text('phaudit.recount_same_person'));
  end if;

  update public.pharmacy_count_round
     set counted_qty = p_qty, method = coalesce(p_method,'type'),
         staff_user_id = auth.uid(), staff_label = v_label, counted_at = now()
   where id = cr.id;

  v_agree := (p_qty = cl.counted_qty);
  update public.pharmacy_count_line
     set status = case when v_agree then 'confirmed' else 'disputed' end,
         resolved_qty = case when v_agree then p_qty else null end
   where id = cl.id;

  perform public.audit_log_append(v_shop, cr.session_id, 'recounted', jsonb_build_object(
    'line_id', cl.id, 'first', cl.counted_qty, 'second', p_qty,
    'agree', v_agree, 'by', v_label));

  return jsonb_build_object('ok', true, 'agree', v_agree,
    'message', case when v_agree then public.ui_text('phaudit.agreed')
                    else public.ui_text('phaudit.disagreed') end);
end $$;

-- The owner settles a disagreement. Only the owner: a disputed line is exactly
-- the case where the two people closest to the shelf could not agree.
create or replace function public.pharmacy_audit_resolve(p_line_id uuid, p_qty numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_shop uuid := public._c430_shop(); cl public.pharmacy_count_line;
        v_owner boolean;
begin
  if v_shop is null then return public._c430_denied(); end if;
  select cl2.* into cl from public.pharmacy_count_line cl2
    join public.pharmacy_count_session s on s.id = cl2.session_id
   where cl2.id = p_line_id and s.pharmacy_id = v_shop;
  if not found then
    return jsonb_build_object('ok', false, 'error','no_line',
                              'message', public.ui_text('phaudit.err_no_line'));
  end if;
  select coalesce((public.pharmacy_shield_entry()->>'is_owner')::boolean, false) into v_owner;
  if not v_owner then
    return jsonb_build_object('ok', false, 'error','owner_only',
                              'message', public.ui_text('phaudit.owner_only'));
  end if;
  if p_qty is null or p_qty < 0 then
    return jsonb_build_object('ok', false, 'error','bad_qty',
                              'message', public.ui_text('phaudit.err_bad_qty'));
  end if;

  update public.pharmacy_count_line
     set resolved_qty = p_qty, resolved_by = auth.uid(), resolved_at = now(),
         status = 'resolved'
   where id = cl.id;

  perform public.audit_log_append(v_shop, cl.session_id, 'owner_resolved',
    jsonb_build_object('line_id', cl.id, 'qty', p_qty));

  return jsonb_build_object('ok', true, 'message', public.ui_text('phaudit.saved'));
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. ACCEPT — the only place an audit is allowed to move the ledger
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.pharmacy_audit_accept(p_session_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_shop uuid := public._c430_shop(); ss public.pharmacy_count_session;
  l public.pharmacy_count_line; v_final numeric; v_delta numeric;
  v_learn jsonb; v_path text; v_n integer := 0; v_value numeric := 0;
  v_label text := public._c430_actor_label(); v_open integer;
begin
  if v_shop is null then return public._c430_denied(); end if;
  select * into ss from public.pharmacy_count_session
   where id = p_session_id and pharmacy_id = v_shop;
  if not found then
    return jsonb_build_object('ok', false, 'error','no_session',
                              'message', public.ui_text('phaudit.err_no_session'));
  end if;

  select count(*) into v_open from public.pharmacy_count_line
   where session_id = ss.id and status = 'disputed';
  if v_open > 0 then
    return jsonb_build_object('ok', false, 'error','disputed_open',
      'message', public.ui_text('phaudit.accept_blocked'), 'disputed', v_open);
  end if;

  for l in
    select * from public.pharmacy_count_line
     where session_id = ss.id
       and status in ('matched','confirmed','resolved','discrepant')
       and coalesce(resolved_qty, counted_qty) is not null
  loop
    v_final := coalesce(l.resolved_qty, l.counted_qty);
    v_delta := v_final - coalesce(l.expected_qty, 0);
    v_path  := 'stock';

    -- A physical count is the strongest fact this system can hold, so it goes
    -- to whichever layer owns "how many are left" — #424's inference where it
    -- is bound (which also recalibrates that SKU's velocity), the shelf
    -- quantity where it is not. Same rule as the radar's one-tap answer (#425);
    -- two different answers to "who owns the number" is how ledgers drift.
    if l.stock_id is not null
       and to_regprocedure('public._c424_correct(uuid,uuid,numeric)') is not null then
      begin
        execute 'select public._c424_correct($1,$2,$3)'
          into v_learn using v_shop, l.stock_id, v_final;
      exception when others then
        v_learn := jsonb_build_object('ok', false, 'error', sqlerrm);
      end;
      if coalesce((v_learn->>'ok')::boolean, false) then v_path := 'inference'; end if;
    end if;

    if v_path = 'stock' and l.stock_id is not null then
      update public.pharmacy_stock set qty = v_final, updated_at = now()
       where id = l.stock_id;
      insert into public.pharmacy_stock_move (
        pharmacy_id, stock_id, item_key, kind, qty_delta, qty_after, unit_cost,
        reason_code, note, actor_user_id, actor_label, ref_kind, ref_id)
      select v_shop, s.id, s.item_key, 'adjust', v_delta, v_final, s.unit_cost,
             case when v_delta < 0 then 'shortage' else 'found' end,
             'stock audit', auth.uid(), v_label, 'audit_line', l.id::text
        from public.pharmacy_stock s where s.id = l.stock_id;
    end if;

    -- Every adjustment is attributed. Who counted it, who confirmed it, what it
    -- was worth.
    insert into public.pharmacy_count_attribution (
      session_id, line_id, staff_user_id, staff_label, variance_qty, variance_value)
    values (ss.id, l.id, coalesce(l.resolved_by, l.counted_by),
            coalesce(l.counted_label, v_label), v_delta,
            round(v_delta * coalesce(l.unit_cost,0), 2));

    v_n := v_n + 1;
    v_value := v_value + abs(round(v_delta * coalesce(l.unit_cost,0), 2));
  end loop;

  update public.pharmacy_count_session
     set status = 'submitted', accepted_at = now(), submitted_at = coalesce(submitted_at, now())
   where id = ss.id;

  perform public.audit_log_append(v_shop, ss.id, 'accepted', jsonb_build_object(
    'lines', v_n, 'value', v_value, 'by', v_label));
  perform public.pharmacy_audit_seal(ss.id);

  return jsonb_build_object('ok', true, 'lines', v_n,
    'value_display', public.inr_money(v_value),
    'message', public.ui_fmt('phaudit.accepted',
       jsonb_build_object('n', public._c430_plural('phaudit.n_lines', v_n))));
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. THE VARIANCE REPORT
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.pharmacy_audit_variance(p_session_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_shop uuid := public._c430_shop(); ss public.pharmacy_count_session;
  l public.pharmacy_count_line; v_rows jsonb := '[]'::jsonb;
  v_short numeric := 0; v_excess numeric := 0; v_match integer := 0;
  v_value numeric := 0; r public.pharmacy_count_round;
begin
  if v_shop is null then return public._c430_denied(); end if;
  select * into ss from public.pharmacy_count_session
   where id = p_session_id and pharmacy_id = v_shop;
  if not found then
    return jsonb_build_object('ok', false, 'error','no_session',
                              'message', public.ui_text('phaudit.err_no_session'));
  end if;

  for l in
    select * from public.pharmacy_count_line
     where session_id = ss.id and counted_qty is not null
     order by abs(coalesce(variance_value,0)) desc, product_name
  loop
    select * into r from public.pharmacy_count_round
     where line_id = l.id and round_no = 2;

    if coalesce(l.variance_qty,0) < 0 then v_short := v_short + abs(l.variance_qty);
    elsif coalesce(l.variance_qty,0) > 0 then v_excess := v_excess + l.variance_qty;
    else v_match := v_match + 1; end if;
    v_value := v_value + abs(coalesce(l.variance_value,0));

    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'line_id', l.id,
      'product_name', coalesce(l.product_name,''),
      'batch_label', case when coalesce(btrim(coalesce(l.batch_no,'')),'') = ''
                          then public.ui_text('phradar.no_batch')
                          else public.ui_fmt('phradar.batch_label',
                                 jsonb_build_object('batch', l.batch_no)) end,
      'counts_label', public.ui_fmt('phaudit.variance_row', jsonb_build_object(
         'counted',  trim(to_char(l.counted_qty,'FM999999990.##')),
         'expected', trim(to_char(coalesce(l.expected_qty,0),'FM999999990.##')))),
      'sold_note', case when coalesce(l.sold_qty,0) > 0
         then public.ui_fmt('phaudit.sold_note',
                jsonb_build_object('n', trim(to_char(l.sold_qty,'FM999999990.##')))) end,
      'variance_label', case when coalesce(l.variance_qty,0) = 0
                             then public.ui_text('phaudit.match_label')
                             when l.variance_qty < 0 then public.ui_text('phaudit.short_label')
                             else public.ui_text('phaudit.excess_label') end,
      'variance_tone', case when coalesce(l.variance_qty,0) = 0 then 'success'
                            when l.variance_qty < 0 then 'danger' else 'warning' end,
      'value_display', public.inr_money(abs(coalesce(l.variance_value,0))),
      'method', l.method,
      'counted_by', coalesce(l.counted_label,''),
      'status', l.status,
      'second_count', case when r.counted_qty is not null
         then trim(to_char(r.counted_qty,'FM999999990.##')) end,
      'second_by', coalesce(r.staff_label,''),
      'needs_photo', l.needs_photo));
  end loop;

  return jsonb_build_object('ok', true,
    'title', public.ui_text('phaudit.close_title'),
    'note',  public.ui_text('phaudit.close_note'),
    'session_id', ss.id, 'status', ss.status,
    'value_label', public.ui_text('phaudit.value_at_stake'),
    'value_display', public.inr_money(v_value),
    'short_label',  public.ui_text('phaudit.short_label'),
    'short_units',  trim(to_char(v_short,'FM999999990.##')),
    'excess_label', public.ui_text('phaudit.excess_label'),
    'excess_units', trim(to_char(v_excess,'FM999999990.##')),
    'match_label',  public.ui_text('phaudit.match_label'),
    'match_count',  v_match,
    'accept_label', public.ui_text('phaudit.accept_button'),
    'can_accept', ss.status = 'closed'
                  and not exists (select 1 from public.pharmacy_count_line
                                   where session_id = ss.id and status = 'disputed'),
    'rows', v_rows);
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. RISK-DIRECTED CYCLE COUNTING
--
-- The yearly shutdown count is the worst of both worlds: it is enormous, and by
-- the time it happens the loss is a year old. Ten items a day, chosen where the
-- system is LEAST sure and where the money is, catches the same losses months
-- earlier and never closes the shop.
-- ─────────────────────────────────────────────────────────────────────────────
-- INTERNAL. It takes a shop id, so it must never be client-reachable: #414's
-- fence journey exists precisely because a shop-id argument on a granted
-- function is a cross-tenant hole waiting for someone to pass a different uuid.
-- The client calls the no-arg wrapper below, which resolves the shop from the
-- login and cannot be pointed at anybody else's shelf.
create or replace function public._c430_cycle_plan(p_shop uuid default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_shop uuid := coalesce(p_shop, public._c430_shop());
  v_cfg public.pharmacy_audit_config; v_rows jsonb := '[]'::jsonb;
  v_ids jsonb := '[]'::jsonb; r record; v_max numeric;
begin
  if v_shop is null then return public._c430_denied(); end if;
  v_cfg := public._c430_cfg(v_shop);

  select greatest(max(coalesce(s.qty,0) * coalesce(s.unit_cost,0)), 1) into v_max
    from public.pharmacy_stock s where s.pharmacy_id = v_shop and coalesce(s.qty,0) > 0;

  for r in
    select s.id, s.product_name, s.batch_no,
           coalesce(s.qty,0) * coalesce(s.unit_cost,0) as value,
           coalesce(i.confidence, 0) as confidence,
           exists (select 1 from public.pharmacy_count_line cl
                     join public.pharmacy_count_session cs on cs.id = cl.session_id
                    where cs.pharmacy_id = v_shop
                      and cl.stock_id = s.id
                      and coalesce(cl.variance_qty, 0) < 0
                      and cs.submitted_at >= now() - interval '90 days') as went_short
      from public.pharmacy_stock s
      left join public.pharmacy_lot_inference i on i.lot_id = s.id
     where s.pharmacy_id = v_shop and coalesce(s.qty,0) > 0
     order by (
       -- least certain (0.5) + most valuable (0.3) + previously short (0.2)
       0.5 * (1 - least(greatest(coalesce(i.confidence,0), 0), 1))
     + 0.3 * (coalesce(s.qty,0) * coalesce(s.unit_cost,0) / v_max)
     + 0.2 * (case when exists (select 1 from public.pharmacy_count_line cl2
                                  join public.pharmacy_count_session cs2 on cs2.id = cl2.session_id
                                 where cs2.pharmacy_id = v_shop and cl2.stock_id = s.id
                                   and coalesce(cl2.variance_qty,0) < 0
                                   and cs2.submitted_at >= now() - interval '90 days')
                   then 1 else 0 end)) desc,
       s.product_name
     limit greatest(coalesce(v_cfg.cycle_size, 10), 1)
  loop
    v_ids := v_ids || to_jsonb(r.id::text);
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'stock_id', r.id,
      'product_name', coalesce(r.product_name,''),
      'batch_label', case when coalesce(btrim(coalesce(r.batch_no,'')),'') = ''
                          then public.ui_text('phradar.no_batch')
                          else public.ui_fmt('phradar.batch_label',
                                 jsonb_build_object('batch', r.batch_no)) end,
      'value_display', public.inr_money(r.value),
      'reason', case when r.went_short then public.ui_text('phaudit.cycle_reason_flag')
                     when r.confidence < 0.5 then public.ui_text('phaudit.cycle_reason_conf')
                     else public.ui_text('phaudit.cycle_reason_value') end));
  end loop;

  insert into public.pharmacy_cycle_plan (pharmacy_id, plan_on, items)
  values (v_shop, public._c413_today(),
          jsonb_build_object('stock_ids', v_ids, 'rows', v_rows))
  on conflict (pharmacy_id, plan_on) do update
    set items = excluded.items, created_at = now();

  return jsonb_build_object('ok', true,
    'title', public.ui_text('phaudit.cycle_title'),
    'note',  public.ui_fmt('phaudit.cycle_note',
               jsonb_build_object('n', jsonb_array_length(v_ids)::text)),
    'empty', public.ui_text('phaudit.cycle_empty'),
    'items', jsonb_build_object('stock_ids', v_ids, 'rows', v_rows),
    'rows',  v_rows);
end $$;

create or replace function public.pharmacy_audit_cycle_plan()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_shop uuid := public._c430_shop();
begin
  if v_shop is null then return public._c430_denied(); end if;
  return public._c430_cycle_plan(v_shop);
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. THE SEAL — hash-chained, verifiable, inspector-grade
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.pharmacy_audit_seal(p_session_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_shop uuid := public._c430_shop(); v_hash text; v_n integer; v_seq integer;
begin
  if v_shop is null then return public._c430_denied(); end if;
  select count(*) into v_n from public.pharmacy_audit_log where session_id = p_session_id;
  v_hash := public.audit_log_append(v_shop, p_session_id, 'sealed',
              jsonb_build_object('entries', v_n));
  select seq into v_seq from public.pharmacy_audit_log
   where pharmacy_id = v_shop order by seq desc limit 1;
  update public.pharmacy_count_session
     set sealed_at = now(), seal_hash = v_hash, seal_events = v_n + 1
   where id = p_session_id and pharmacy_id = v_shop;
  return jsonb_build_object('ok', true, 'hash', v_hash, 'entries', v_n + 1, 'seq', v_seq);
end $$;

-- Recompute the whole chain and say exactly where it breaks. A tampered payload
-- or a deleted row changes every hash after it, so "unbroken" is a real claim
-- and not a badge.
create or replace function public.pharmacy_audit_verify(p_session_id uuid default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_shop uuid := public._c430_shop(); r record; v_prev text := null;
  v_calc text; v_n integer := 0; v_bad integer := null;
begin
  if v_shop is null then return public._c430_denied(); end if;
  for r in
    select * from public.pharmacy_audit_log
     where pharmacy_id = v_shop order by seq
  loop
    v_calc := encode(extensions.digest(
      coalesce(v_prev,'') || '|' || r.seq::text || '|' || r.event || '|' ||
      coalesce(r.session_id::text,'') || '|' || coalesce(r.payload::text,'{}') || '|' ||
      to_char(r.at, 'YYYY-MM-DD"T"HH24:MI:SS.USOF'), 'sha256'), 'hex');
    v_n := v_n + 1;
    if v_calc <> r.hash and v_bad is null then v_bad := r.seq; end if;
    v_prev := r.hash;
  end loop;

  if v_n = 0 then
    return jsonb_build_object('ok', true, 'sealed', false, 'entries', 0,
      'title', public.ui_text('phaudit.seal_title'),
      'label', public.ui_text('phaudit.seal_none'), 'tone', 'neutral');
  end if;

  return jsonb_build_object('ok', true, 'sealed', true, 'entries', v_n,
    'intact', v_bad is null, 'broken_at', v_bad,
    'title', public.ui_text('phaudit.seal_title'),
    'label', case when v_bad is null
      then public.ui_fmt('phaudit.seal_ok', jsonb_build_object('n', v_n::text))
      else public.ui_fmt('phaudit.seal_broken', jsonb_build_object('seq', v_bad::text)) end,
    'tone', case when v_bad is null then 'success' else 'danger' end,
    'head_hash', v_prev);
end $$;

-- The artefact a bank or an insurer is handed: counted stock at cost, tied to a
-- sealed physical count by its hash — not a number typed into a letter.
create or replace function public.pharmacy_audit_certificate(p_session_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_shop uuid := public._c430_shop(); ss public.pharmacy_count_session;
  v_value numeric; v_lines integer; v_seq integer; v_name text;
begin
  if v_shop is null then return public._c430_denied(); end if;
  select * into ss from public.pharmacy_count_session
   where id = p_session_id and pharmacy_id = v_shop;
  if not found then
    return jsonb_build_object('ok', false, 'error','no_session',
                              'message', public.ui_text('phaudit.err_no_session'));
  end if;

  select coalesce(sum(coalesce(resolved_qty, counted_qty) * coalesce(unit_cost,0)), 0),
         count(*)
    into v_value, v_lines
    from public.pharmacy_count_line
   where session_id = ss.id and coalesce(resolved_qty, counted_qty) is not null;

  select seq into v_seq from public.pharmacy_audit_log
   where session_id = ss.id order by seq desc limit 1;
  select pharmacy_name into v_name from public.pharmacy_profiles where id = v_shop;

  return jsonb_build_object('ok', true,
    'title', public.ui_text('phaudit.cert_title'),
    'shop', coalesce(v_name,''),
    'line', public.ui_fmt('phaudit.cert_line', jsonb_build_object(
      'date', to_char(coalesce(ss.submitted_at, ss.closed_at, now())
                        at time zone 'Asia/Kolkata', 'DD/MM/YYYY'),
      'value', public.inr_money(v_value))),
    'note', public.ui_fmt('phaudit.cert_note', jsonb_build_object(
      'seq', coalesce(v_seq, 0)::text,
      'hash', coalesce(left(ss.seal_hash, 16), '-'))),
    'value_display', public.inr_money(v_value),
    'lines', v_lines,
    'sealed', ss.seal_hash is not null,
    'seal_hash', ss.seal_hash);
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. WHAT TO DO NEXT — an audit that ends in a number ends too early
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.pharmacy_audit_actions(p_session_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_shop uuid := public._c430_shop(); ss public.pharmacy_count_session;
  v_short integer; v_excess integer; v_zero integer; v_rows jsonb := '[]'::jsonb;
begin
  if v_shop is null then return public._c430_denied(); end if;
  select * into ss from public.pharmacy_count_session
   where id = p_session_id and pharmacy_id = v_shop;
  if not found then
    return jsonb_build_object('ok', false, 'error','no_session',
                              'message', public.ui_text('phaudit.err_no_session'));
  end if;

  select count(*) into v_short from public.pharmacy_count_line
   where session_id = ss.id and coalesce(variance_qty,0) < 0;

  -- Extra stock is only a problem when it is also about to expire; that is the
  -- pile the exchange (#420) exists for.
  select count(*) into v_excess from public.pharmacy_count_line cl
   where cl.session_id = ss.id and coalesce(cl.variance_qty,0) > 0
     and cl.expiry_on is not null
     and cl.expiry_on <= public._c413_today() + 90;

  -- A fast mover counted at zero is a sale you are about to lose, not a
  -- discrepancy.
  select count(*) into v_zero from public.pharmacy_count_line cl
    left join public.pharmacy_lot_inference i on i.lot_id = cl.stock_id
   where cl.session_id = ss.id and cl.counted_qty = 0
     and coalesce(i.per_day, 0) > 0;

  if v_short > 0 then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'key','theft', 'tone','danger',
      'label', public.ui_fmt('phaudit.action_theft', jsonb_build_object('n', v_short::text)),
      'route_key','pharmacy_stock_check', 'count', v_short));
  end if;
  if v_excess > 0 then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'key','exchange', 'tone','warning',
      'label', public.ui_fmt('phaudit.action_exchange', jsonb_build_object('n', v_excess::text)),
      'route_key','pharmacy_px', 'count', v_excess));
  end if;
  if v_zero > 0 then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'key','reorder', 'tone','info',
      'label', public.ui_fmt('phaudit.action_reorder', jsonb_build_object('n', v_zero::text)),
      'route_key','pharmacy_reorder', 'count', v_zero));
  end if;

  return jsonb_build_object('ok', true,
    'title', public.ui_text('phaudit.actions_title'),
    'rows', v_rows,
    'empty', public.ui_text('phaudit.actions_none'));
end $$;

create or replace function public.pharmacy_audit_trend(p_limit integer default 6)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_shop uuid := public._c430_shop(); r record; v_rows jsonb := '[]'::jsonb;
begin
  if v_shop is null then return public._c430_denied(); end if;
  for r in
    select public._c419_category(cl.product_name) as cat,
           sum(case when coalesce(cl.variance_qty,0) < 0
                    then abs(coalesce(cl.variance_value,0)) else 0 end) as shrink,
           count(*) as lines
      from public.pharmacy_count_line cl
      join public.pharmacy_count_session cs on cs.id = cl.session_id
     where cs.pharmacy_id = v_shop and cs.submitted_at is not null
       and cs.submitted_at >= now() - interval '180 days'
     group by 1
     having sum(case when coalesce(cl.variance_qty,0) < 0
                     then abs(coalesce(cl.variance_value,0)) else 0 end) > 0
     order by 2 desc
     limit greatest(coalesce(p_limit,6),1)
  loop
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'category', r.cat,
      'value_display', public.inr_money(r.shrink),
      'lines_label', public._c430_plural('phaudit.n_lines', r.lines::int)));
  end loop;
  return jsonb_build_object('ok', true,
    'title', public.ui_text('phaudit.trend_title'),
    'rows', v_rows, 'empty', public.ui_text('phaudit.trend_empty'));
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 8. THE SCREEN'S ONE CALL, and the way in
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.pharmacy_audit_entry()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_shop uuid := public._c430_shop(); v_open uuid;
begin
  if v_shop is null then return jsonb_build_object('ok', true, 'show', false); end if;
  select id into v_open from public.pharmacy_count_session
   where pharmacy_id = v_shop and status = 'open' order by started_at desc limit 1;
  return jsonb_build_object('ok', true, 'show', true,
    'label', public.ui_text('phaudit.nav_label'),
    'sub_label', public.ui_text('phaudit.nav_sub'),
    'badge', case when v_open is not null then public.ui_text('phaudit.open_title') end,
    'route_key', 'pharmacy_audit');
end $$;

create or replace function public.pharmacy_audit_home()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_shop uuid := public._c430_shop(); ss public.pharmacy_count_session;
  v_cfg public.pharmacy_audit_config; r record; v_recent jsonb := '[]'::jsonb;
  v_plan jsonb; v_done integer; v_total integer;
begin
  if v_shop is null then return public._c430_denied(); end if;
  v_cfg := public._c430_cfg(v_shop);

  select * into ss from public.pharmacy_count_session
   where pharmacy_id = v_shop and status in ('open','closed')
   order by started_at desc limit 1;

  if ss.id is not null then
    select count(*) filter (where counted_qty is not null), count(*)
      into v_done, v_total from public.pharmacy_count_line where session_id = ss.id;
  end if;

  select items into v_plan from public.pharmacy_cycle_plan
   where pharmacy_id = v_shop and plan_on = public._c413_today();
  if v_plan is null then v_plan := public._c430_cycle_plan(v_shop)->'items'; end if;

  for r in
    select * from public.pharmacy_count_session
     where pharmacy_id = v_shop and status = 'submitted'
     order by coalesce(submitted_at, started_at) desc limit 5
  loop
    v_recent := v_recent || jsonb_build_array(jsonb_build_object(
      'session_id', r.id,
      'label', coalesce(r.label, public.ui_text('phaudit.kind_spot')),
      'date_label', to_char(coalesce(r.submitted_at, r.started_at)
                              at time zone 'Asia/Kolkata', 'DD/MM/YY'),
      'lines_label', public._c430_plural('phaudit.n_lines', coalesce(r.sku_count,0)),
      'value_display', public.inr_money(coalesce(r.variance_value,0)),
      'sealed', r.seal_hash is not null));
  end loop;

  return jsonb_build_object('ok', true,
    'title', public.ui_text('phaudit.title'),
    'start_title', public.ui_text('phaudit.start_title'),
    'start_note',  public.ui_text('phaudit.start_note'),
    'scope_hint',  public.ui_text('phaudit.scope_hint'),
    'kinds', jsonb_build_array(
      jsonb_build_object('key','full',   'scope','shop',    'label', public.ui_text('phaudit.kind_full')),
      jsonb_build_object('key','partial','scope','rack',    'label', public.ui_text('phaudit.kind_partial'), 'needs_value', true),
      jsonb_build_object('key','cycle',  'scope','cycle',   'label', public.ui_text('phaudit.kind_cycle'))),
    'open', case when ss.id is null then null else jsonb_build_object(
      'session_id', ss.id, 'status', ss.status,
      'title', public.ui_text('phaudit.open_title'),
      'label', coalesce(ss.label,''),
      'progress_label', public.ui_fmt('phaudit.open_note',
        jsonb_build_object('done', coalesce(v_done,0)::text, 'total', coalesce(v_total,0)::text))) end,
    'cycle', jsonb_build_object(
      'title', public.ui_text('phaudit.cycle_title'),
      'note',  public.ui_fmt('phaudit.cycle_note', jsonb_build_object(
                 'n', coalesce(jsonb_array_length(v_plan->'rows'),0)::text)),
      'rows',  coalesce(v_plan->'rows','[]'::jsonb),
      'empty', public.ui_text('phaudit.cycle_empty')),
    'recent', v_recent,
    'seal', public.pharmacy_audit_verify(null),
    'trend', public.pharmacy_audit_trend(6));
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 9. ONE SYSTEM, NOT TWO
--
-- #413's spot count writes to these same tables (its sessions already land as
-- kind='spot'), so the only thing missing was the seal: a spot check has to
-- appear in the same sealed record as a full audit, or the record has a hole in
-- it exactly where a quick count happened. This trigger puts it there without
-- touching #413's own functions or its screen.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.trg_c430_session_sealed()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if tg_op = 'INSERT' then
    -- The audit's own RPCs append their entries themselves, so this only picks
    -- up sessions born elsewhere — #413's spot check.
    if coalesce(new.kind, 'spot') <> 'spot' then return new; end if;
    perform public.audit_log_append(new.pharmacy_id, new.id, 'session_started',
      jsonb_build_object('kind', new.kind, 'sku_count', new.sku_count,
                         'source', 'spot_check'));
  elsif tg_op = 'UPDATE' and coalesce(old.status,'') <> 'submitted'
        and new.status = 'submitted' then
    perform public.audit_log_append(new.pharmacy_id, new.id, 'session_submitted',
      jsonb_build_object('kind', new.kind, 'variance_units', new.variance_units,
                         'variance_value', new.variance_value));
  end if;
  return new;
exception when others then
  return new;   -- the log must never block a count
end $$;

drop trigger if exists c430_session_seal_trg on public.pharmacy_count_session;
create trigger c430_session_seal_trg
after insert or update of status on public.pharmacy_count_session
for each row execute function public.trg_c430_session_sealed();

grant execute on function public.pharmacy_audit_entry() to authenticated;
grant execute on function public.pharmacy_audit_home() to authenticated;
grant execute on function public.pharmacy_audit_close(uuid) to authenticated;
grant execute on function public.pharmacy_audit_variance(uuid) to authenticated;
grant execute on function public.pharmacy_audit_recount_sheet(uuid) to authenticated;
grant execute on function public.pharmacy_audit_recount(uuid, numeric, text) to authenticated;
grant execute on function public.pharmacy_audit_resolve(uuid, numeric) to authenticated;
grant execute on function public.pharmacy_audit_accept(uuid) to authenticated;
grant execute on function public.pharmacy_audit_cycle_plan() to authenticated;
revoke execute on function public._c430_cycle_plan(uuid) from authenticated, anon;
grant execute on function public.pharmacy_audit_seal(uuid) to authenticated;
grant execute on function public.pharmacy_audit_verify(uuid) to authenticated;
grant execute on function public.pharmacy_audit_certificate(uuid) to authenticated;
grant execute on function public.pharmacy_audit_actions(uuid) to authenticated;
grant execute on function public.pharmacy_audit_trend(integer) to authenticated;
