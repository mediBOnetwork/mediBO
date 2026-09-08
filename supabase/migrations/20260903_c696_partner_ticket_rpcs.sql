-- CHANGE #696 (2/3) — every word the channel prints, and the six calls the
-- screen makes.
--
-- There is not one display string in the Dart. Category names, priority words,
-- the SLA sentence and its colour, the closure outcomes, every refusal and
-- every toast are resolved here, so renaming "Count dispute" is an UPDATE.

insert into public.ui_copy (key, value) values
  -- screen chrome
  ('pt.title',              '"Partner issues"'::jsonb),
  ('pt.title_partner',      '"My issues"'::jsonb),
  ('pt.subtitle_partner',   '"Anything stuck with mediBO — raise it here and watch the clock."'::jsonb),
  ('pt.subtitle_office',    '"Every issue open with a zone partner, the closest to breaching first."'::jsonb),
  ('pt.raise_cta',          '"Raise issue"'::jsonb),
  ('pt.empty_title',        '"Nothing open"'::jsonb),
  ('pt.empty_note_partner', '"Raise an issue and the mediBO office owns it from that moment."'::jsonb),
  ('pt.empty_note_office',  '"No partner is waiting on the office right now."'::jsonb),
  ('pt.empty_filtered',     '"Nothing under this filter."'::jsonb),
  ('pt.count_one',          '"1 open issue"'::jsonb),
  ('pt.count_many',         '"{n} open issues"'::jsonb),
  ('pt.badge_label',        '"{n} waiting"'::jsonb),
  ('pt.retry',              '"Try again"'::jsonb),
  -- filters
  ('pt.filter_open',        '"Open"'::jsonb),
  ('pt.filter_breached',    '"Overdue"'::jsonb),
  ('pt.filter_mine',        '"On me"'::jsonb),
  ('pt.filter_closed',      '"Closed"'::jsonb),
  ('pt.filter_all',         '"All"'::jsonb),
  -- categories
  ('pt.cat.order',                 '"Order"'::jsonb),
  ('pt.cat.order.hint',            '"Something wrong with a customer order."'::jsonb),
  ('pt.cat.supplier',              '"Supplier"'::jsonb),
  ('pt.cat.supplier.hint',         '"A supplier who is not answering, or quoting wrong."'::jsonb),
  ('pt.cat.payment',               '"Payment"'::jsonb),
  ('pt.cat.payment.hint',          '"A settlement, payout or claim that has not moved."'::jsonb),
  ('pt.cat.app_bug',               '"App problem"'::jsonb),
  ('pt.cat.app_bug.hint',          '"Something in the app is broken or wrong."'::jsonb),
  ('pt.cat.delivery',              '"Delivery"'::jsonb),
  ('pt.cat.delivery.hint',         '"A rider, a run or a handover that has gone wrong."'::jsonb),
  ('pt.cat.sla_breach',            '"SLA breach"'::jsonb),
  ('pt.cat.sla_breach.hint',       '"The zone missed a promise mediBO made to a customer."'::jsonb),
  ('pt.cat.count_dispute',         '"Count dispute"'::jsonb),
  ('pt.cat.count_dispute.hint',    '"Shop count and warehouse recount disagree."'::jsonb),
  ('pt.cat.settlement_query',      '"Settlement query"'::jsonb),
  ('pt.cat.settlement_query.hint', '"A line on the statement the office needs explained."'::jsonb),
  -- priorities
  ('pt.pri.urgent',         '"Urgent"'::jsonb),
  ('pt.pri.high',           '"High"'::jsonb),
  ('pt.pri.normal',         '"Normal"'::jsonb),
  ('pt.pri.low',            '"Low"'::jsonb),
  -- statuses
  ('pt.status.open',        '"Open"'::jsonb),
  ('pt.status.waiting',     '"Waiting on you"'::jsonb),
  ('pt.status.waiting_them','"Waiting on them"'::jsonb),
  ('pt.status.resolved',    '"Resolved"'::jsonb),
  ('pt.status.closed',      '"Closed"'::jsonb),
  -- owners and sides
  ('pt.owner.medibo',       '"mediBO office"'::jsonb),
  ('pt.owner.partner',      '"Partner"'::jsonb),
  ('pt.side.system',        '"mediBO"'::jsonb),
  ('pt.you',                '"You"'::jsonb),
  ('pt.owner_line',         '"With {owner}"'::jsonb),
  ('pt.raised_line',        '"Raised by {who} · {when}"'::jsonb),
  -- the clock
  ('pt.sla_due',            '"Reply due {at}"'::jsonb),
  ('pt.sla_soon',           '"Due in under half the time left"'::jsonb),
  ('pt.sla_breached',       '"Overdue by {age}"'::jsonb),
  ('pt.sla_closed',         '"Closed {when}"'::jsonb),
  ('pt.sla_none',           '"No clock on this one"'::jsonb),
  ('pt.first_reply',        '"First reply {age}"'::jsonb),
  -- the raise sheet
  ('pt.new_title',          '"Raise an issue"'::jsonb),
  ('pt.new_title_office',   '"Raise an issue with a partner"'::jsonb),
  ('pt.new_category',       '"What is it about?"'::jsonb),
  ('pt.new_priority',       '"How urgent?"'::jsonb),
  ('pt.new_partner',        '"Which partner?"'::jsonb),
  ('pt.new_subject',        '"Subject"'::jsonb),
  ('pt.new_subject_hint',   '"One line — what is wrong"'::jsonb),
  ('pt.new_body_hint',      '"What happened, and what you need"'::jsonb),
  ('pt.new_link_hint',      '"Order code, supplier or statement this is about (optional)"'::jsonb),
  ('pt.new_submit',         '"Raise it"'::jsonb),
  ('pt.new_sla_line',       '"Answer promised within {hours}"'::jsonb),
  ('pt.raised_toast',       '"Raised — {ref}"'::jsonb),
  -- the thread
  ('pt.compose_hint',       '"Write a reply"'::jsonb),
  ('pt.send_cta',           '"Send"'::jsonb),
  ('pt.attach_cta',         '"Attach"'::jsonb),
  ('pt.sent_toast',         '"Sent"'::jsonb),
  ('pt.attach_open',        '"Open"'::jsonb),
  ('pt.timeline_title',     '"Timeline"'::jsonb),
  ('pt.system_raised',      '"Issue raised — {cat} · answer promised within {hours}."'::jsonb),
  ('pt.system_nudge',       '"Half the promised time has gone — nudged on WhatsApp."'::jsonb),
  ('pt.system_breach',      '"Promised time passed — sent to the mediBO ops inbox."'::jsonb),
  ('pt.system_closed',      '"Closed as {outcome}."'::jsonb),
  -- the linked object
  ('pt.link.order',         '"Order {ref}"'::jsonb),
  ('pt.link.supplier',      '"Supplier"'::jsonb),
  ('pt.link.settlement',    '"Settlement"'::jsonb),
  ('pt.link_cta',           '"Open"'::jsonb),
  -- closing
  ('pt.close_cta',          '"Close issue"'::jsonb),
  ('pt.close_title',        '"How did this end?"'::jsonb),
  ('pt.close_hint',         '"Pick an outcome — it is what the partner scorecard counts."'::jsonb),
  ('pt.close_note_hint',    '"Anything worth writing down (optional)"'::jsonb),
  ('pt.close_submit',       '"Close it"'::jsonb),
  ('pt.closed_toast',       '"Closed"'::jsonb),
  ('pt.closed_line',        '"Closed {when} · {outcome}"'::jsonb),
  ('pt.out.fixed',             '"Fixed"'::jsonb),
  ('pt.out.partner_corrected', '"Partner corrected it"'::jsonb),
  ('pt.out.medibo_corrected',  '"mediBO corrected it"'::jsonb),
  ('pt.out.supplier_at_fault', '"Supplier at fault"'::jsonb),
  ('pt.out.no_fault',          '"Nobody at fault"'::jsonb),
  ('pt.out.duplicate',         '"Duplicate"'::jsonb),
  ('pt.out.not_actioned',      '"Not actioned"'::jsonb),
  ('pt.out.withdrawn',         '"Withdrawn"'::jsonb),
  -- refusals
  ('pt.err_not_yours',      '"This issue is not yours to open."'::jsonb),
  ('pt.err_no_ticket',      '"That issue no longer exists."'::jsonb),
  ('pt.err_empty',          '"Write something first."'::jsonb),
  ('pt.err_no_subject',     '"Give it a one-line subject."'::jsonb),
  ('pt.err_no_category',    '"Pick what it is about."'::jsonb),
  ('pt.err_no_partner',     '"Pick the partner this is about."'::jsonb),
  ('pt.err_no_outcome',     '"Pick an outcome before closing."'::jsonb),
  ('pt.err_closed',         '"This issue is already closed."'::jsonb),
  ('pt.err_not_partner',    '"Only a mediBO partner or the office can use this."'::jsonb),
  -- the ops inbox row
  ('exc.reason.partner_ticket_breach', '"Partner issue overdue"'::jsonb),
  ('exc.action.partner_ticket_breach', '"Open the issue"'::jsonb)
on conflict (key) do update set value = excluded.value, updated_at = now();

-- ── who is asking ───────────────────────────────────────────────────────────
-- 'medibo' for the office, 'partner' for a partner login, null for anyone
-- else. Every RPC below refuses on null with the backend's own sentence.
create or replace function public._pt_actor()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_pid bigint; v_name text;
begin
  v_pid := public.my_partner_id();
  if v_pid is not null and not public._is_admin() then
    select rp.partner_name into v_name from public.region_partners rp where rp.id = v_pid;
    return jsonb_build_object('side','partner','id', auth.uid(), 'partner_id', v_pid,
      'label', coalesce(nullif(v_name,''), public._c('pt.owner.partner')));
  end if;
  if public._is_admin() then
    return jsonb_build_object('side','medibo','id', auth.uid(), 'partner_id', null,
      'label', public._c('pt.owner.medibo'));
  end if;
  return jsonb_build_object('side','', 'id', auth.uid(), 'partner_id', null, 'label','');
end $$;

-- ── the clock: business hours in IST, the same window #713 promises on ──────
create or replace function public._pt_due(p_from timestamptz, p_hours numeric)
returns timestamptz language sql stable security definer set search_path to 'public' as $$
  select public._thread_business_due(
           p_from,
           greatest(round(coalesce(p_hours,0) * 60)::int, 0),
           c.business_start_ist, c.business_end_ist)
    from public.partner_ticket_config c where c.id = 1;
$$;

-- ── the SLA sentence and its colour, for one ticket ─────────────────────────
create or replace function public._pt_sla_block(t public.partner_ticket)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  if t.status = 'closed' then
    return jsonb_build_object(
      'label', public._cf('pt.sla_closed', jsonb_build_object('when', public._ist_stamp(t.closed_at))),
      'tone', 'neutral', 'breached', false);
  end if;
  if t.sla_due_at is null then
    return jsonb_build_object('label', public._c('pt.sla_none'), 'tone','neutral','breached', false);
  end if;
  if now() > t.sla_due_at then
    return jsonb_build_object(
      'label', public._cf('pt.sla_breached', jsonb_build_object('age', public._ist_age(t.sla_due_at))),
      'tone', 'danger', 'breached', true);
  end if;
  if t.nudge_due_at is not null and now() > t.nudge_due_at then
    return jsonb_build_object('label', public._c('pt.sla_soon'), 'tone','warning','breached', false);
  end if;
  return jsonb_build_object(
    'label', public._cf('pt.sla_due', jsonb_build_object('at', public._ist_stamp(t.sla_due_at))),
    'tone', 'info', 'breached', false);
end $$;

-- ── one row, as the list prints it ──────────────────────────────────────────
create or replace function public._pt_row(t public.partner_ticket, p_side text)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_cat public.partner_ticket_category; v_pri public.partner_ticket_priority;
        v_sla jsonb; v_status text; v_tone text; v_partner text;
begin
  select * into v_cat from public.partner_ticket_category where code = t.category_code;
  select * into v_pri from public.partner_ticket_priority where code = t.priority;
  v_sla := public._pt_sla_block(t);
  select rp.partner_name into v_partner from public.region_partners rp where rp.id = t.partner_id;

  -- "Waiting on you" is a different sentence depending on who is reading it,
  -- and that decision is made HERE, never by the client.
  if t.status = 'closed' then
    v_status := public._c('pt.status.closed'); v_tone := 'neutral';
  elsif t.status = 'resolved' then
    v_status := public._c('pt.status.resolved'); v_tone := 'success';
  elsif t.owner_side = p_side then
    v_status := public._c('pt.status.waiting'); v_tone := 'warning';
  else
    v_status := public._c('pt.status.waiting_them'); v_tone := 'info';
  end if;

  return jsonb_build_object(
    'id',             t.id::text,
    'ref',            coalesce(t.ref,''),
    'subject',        coalesce(nullif(t.subject,''), coalesce(public._c(v_cat.label_key),'')),
    'category_label', coalesce(public._c(v_cat.label_key), t.category_code),
    'priority_label', coalesce(public._c(v_pri.label_key), t.priority),
    'priority_tone',  coalesce(v_pri.tone,'info'),
    'status_label',   v_status,
    'status_tone',    v_tone,
    'owner_label',    public._cf('pt.owner_line', jsonb_build_object('owner',
                        case when t.owner_side = 'medibo' then public._c('pt.owner.medibo')
                             else coalesce(nullif(v_partner,''), public._c('pt.owner.partner')) end)),
    'partner_label',  coalesce(nullif(v_partner,''), ''),
    'sla_label',      v_sla->>'label',
    'sla_tone',       v_sla->>'tone',
    'breached',       coalesce((v_sla->>'breached')::boolean, false),
    'age_label',      public._ist_age(coalesce(t.last_message_at, t.created_at)),
    'is_closed',      (t.status = 'closed'),
    'mine',           (t.owner_side = p_side));
end $$;

-- ── the list ────────────────────────────────────────────────────────────────
-- Zone-scoped by construction: a partner login can only ever be handed their
-- OWN partner_id, and the office sees every zone. There is no client filter.
create or replace function public.partner_ticket_list(
  p_filter text default 'open', p_partner_id bigint default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  a jsonb := public._pt_actor(); v_side text; v_pid bigint;
  -- Row-typed, not a record: _pt_row() takes the table's composite type, and a
  -- bare `record` cannot be cast to one.
  v_rows jsonb := '[]'::jsonb; r public.partner_ticket;
  v_filter text := coalesce(nullif(p_filter,''),'open');
  v_open int := 0; v_breach int := 0; v_mine int := 0; v_closed int := 0; v_all int := 0;
begin
  v_side := a->>'side';
  if v_side = '' then
    return jsonb_build_object('ok', false, 'message', public._c('pt.err_not_partner'));
  end if;
  v_pid := case when v_side = 'partner' then (a->>'partner_id')::bigint else p_partner_id end;

  select count(*) filter (where t.status <> 'closed'),
         count(*) filter (where t.status <> 'closed' and t.sla_due_at < now()),
         count(*) filter (where t.status <> 'closed' and t.owner_side = v_side),
         count(*) filter (where t.status = 'closed'),
         count(*)
    into v_open, v_breach, v_mine, v_closed, v_all
    from public.partner_ticket t
   where (v_pid is null or t.partner_id = v_pid);

  for r in
    select t.* from public.partner_ticket t
     where (v_pid is null or t.partner_id = v_pid)
       and case v_filter
             when 'open'     then t.status <> 'closed'
             when 'breached' then t.status <> 'closed' and t.sla_due_at < now()
             when 'mine'     then t.status <> 'closed' and t.owner_side = v_side
             when 'closed'   then t.status = 'closed'
             else true end
     -- breach first, then the closest to breaching. This is the "sorted by
     -- breach" the office asked for, and the partner gets the same order.
     order by (t.status = 'closed'),
              (t.status <> 'closed' and t.sla_due_at < now()) desc,
              t.sla_due_at asc nulls last,
              t.created_at desc
     limit 200
  loop
    v_rows := v_rows || jsonb_build_array(public._pt_row(r, v_side));
  end loop;

  return jsonb_build_object(
    'ok', true,
    'view', case when v_side = 'partner' then 'partner' else 'office' end,
    'title', case when v_side = 'partner' then public._c('pt.title_partner') else public._c('pt.title') end,
    'subtitle', case when v_side = 'partner' then public._c('pt.subtitle_partner')
                     else public._c('pt.subtitle_office') end,
    'raise_cta', public._c('pt.raise_cta'),
    'can_raise', true,
    'filter', v_filter,
    'filters', jsonb_build_array(
      jsonb_build_object('key','open',    'label', public._c('pt.filter_open'),     'count', v_open),
      jsonb_build_object('key','breached','label', public._c('pt.filter_breached'), 'count', v_breach),
      jsonb_build_object('key','mine',    'label', public._c('pt.filter_mine'),     'count', v_mine),
      jsonb_build_object('key','closed',  'label', public._c('pt.filter_closed'),   'count', v_closed),
      jsonb_build_object('key','all',     'label', public._c('pt.filter_all'),      'count', v_all)),
    'rows', v_rows,
    'count_label', case when v_open = 1 then public._c('pt.count_one')
                        else public._cf('pt.count_many', jsonb_build_object('n', v_open::text)) end,
    'empty_title', public._c('pt.empty_title'),
    'empty_note', case when v_filter in ('open','all')
                       then case when v_side = 'partner' then public._c('pt.empty_note_partner')
                                 else public._c('pt.empty_note_office') end
                       else public._c('pt.empty_filtered') end,
    'retry_label', public._c('pt.retry'));
end $$;

-- ── the raise sheet ─────────────────────────────────────────────────────────
create or replace function public.partner_ticket_new()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare a jsonb := public._pt_actor(); v_side text; v_cats jsonb := '[]'::jsonb;
        v_pris jsonb := '[]'::jsonb; v_partners jsonb := '[]'::jsonb; r record;
begin
  v_side := a->>'side';
  if v_side = '' then
    return jsonb_build_object('ok', false, 'message', public._c('pt.err_not_partner'));
  end if;

  for r in select * from public.partner_ticket_category
            where active and direction = v_side order by sort_order loop
    v_cats := v_cats || jsonb_build_array(jsonb_build_object(
      'code', r.code,
      'label', coalesce(public._c(r.label_key), r.code),
      'hint',  coalesce(public._c(r.hint_key), ''),
      'link_kind', r.link_kind,
      'priority', r.default_priority,
      'sla_label', public._cf('pt.new_sla_line',
                     jsonb_build_object('hours', public._fmt_dur(r.sla_hours * 3600)))));
  end loop;

  for r in select * from public.partner_ticket_priority where active order by sort_order loop
    v_pris := v_pris || jsonb_build_array(jsonb_build_object(
      'code', r.code, 'label', coalesce(public._c(r.label_key), r.code), 'tone', r.tone));
  end loop;

  -- The office must name the partner; a partner never can (and is never asked).
  if v_side = 'medibo' then
    for r in select rp.id, rp.partner_name, rp.zone_id from public.region_partners rp
              where rp.is_active and rp.suspended_at is null order by rp.id loop
      v_partners := v_partners || jsonb_build_array(jsonb_build_object(
        'id', r.id::text,
        'label', coalesce(nullif(r.partner_name,''), 'Partner ' || r.id::text)));
    end loop;
  end if;

  return jsonb_build_object(
    'ok', true, 'side', v_side,
    'title', case when v_side = 'partner' then public._c('pt.new_title')
                  else public._c('pt.new_title_office') end,
    'category_label', public._c('pt.new_category'),
    'priority_label', public._c('pt.new_priority'),
    'partner_label',  public._c('pt.new_partner'),
    'subject_label',  public._c('pt.new_subject'),
    'subject_hint',   public._c('pt.new_subject_hint'),
    'body_hint',      public._c('pt.new_body_hint'),
    'link_hint',      public._c('pt.new_link_hint'),
    'submit_cta',     public._c('pt.new_submit'),
    'needs_partner',  (v_side = 'medibo'),
    'categories', v_cats, 'priorities', v_pris, 'partners', v_partners,
    -- Where an attachment goes. The client never composes a storage path: a
    -- partner may only write under their own 'p<id>' prefix and this is the
    -- one place that rule is written.
    'upload', jsonb_build_object(
      'bucket', 'partner-issue-files',
      'folder', case when v_side = 'partner'
                     then 'p' || coalesce((a->>'partner_id'),'0') || '/draft'
                     else '' end,
      'cta', public._c('pt.attach_cta')));
end $$;

-- ── raise ───────────────────────────────────────────────────────────────────
create or replace function public.partner_ticket_raise(
  p_category text, p_subject text, p_body text,
  p_priority text default '', p_partner_id bigint default null,
  p_link_kind text default '', p_link_ref text default '',
  p_attachments jsonb default '[]'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  a jsonb := public._pt_actor(); v_side text; v_cat public.partner_ticket_category;
  v_factor numeric := 1; v_pri text; v_pid bigint; v_zone bigint;
  v_hours numeric; v_due timestamptz; v_id uuid; v_ref text; v_owner text;
begin
  v_side := a->>'side';
  if v_side = '' then
    return jsonb_build_object('ok', false, 'message', public._c('pt.err_not_partner'));
  end if;

  select * into v_cat from public.partner_ticket_category
   where code = coalesce(nullif(btrim(p_category),''),'') and active and direction = v_side;
  if v_cat.code is null then
    return jsonb_build_object('ok', false, 'message', public._c('pt.err_no_category'));
  end if;
  if coalesce(btrim(p_subject),'') = '' then
    return jsonb_build_object('ok', false, 'message', public._c('pt.err_no_subject'));
  end if;

  v_pid := case when v_side = 'partner' then (a->>'partner_id')::bigint else p_partner_id end;
  if v_pid is null then
    return jsonb_build_object('ok', false, 'message', public._c('pt.err_no_partner'));
  end if;
  select rp.zone_id into v_zone from public.region_partners rp where rp.id = v_pid;

  v_pri := coalesce(nullif(btrim(p_priority),''), v_cat.default_priority);
  select coalesce(sla_factor,1) into v_factor from public.partner_ticket_priority
   where code = v_pri and active;
  if v_factor is null then v_pri := v_cat.default_priority; v_factor := 1; end if;

  v_hours := round(v_cat.sla_hours * v_factor, 2);
  v_due   := public._pt_due(now(), v_hours);
  -- The owner is the OTHER side, always. A partner's issue is the office's to
  -- answer; the office's issue is the partner's.
  v_owner := case when v_side = 'partner' then 'medibo' else 'partner' end;
  v_ref   := 'PT-' || lpad(nextval('public.partner_ticket_ref_seq')::text, 5, '0');

  insert into public.partner_ticket
    (ref, partner_id, zone_id, raised_side, raised_by, raised_by_label, owner_side,
     category_code, priority, subject, status, link_kind, link_ref,
     sla_hours, sla_due_at, nudge_due_at, last_message_at, last_actor_side)
  values
    (v_ref, v_pid, v_zone, v_side, auth.uid(), coalesce(a->>'label',''), v_owner,
     v_cat.code, v_pri, btrim(p_subject), 'open',
     coalesce(nullif(btrim(p_link_kind),''), v_cat.link_kind),
     coalesce(btrim(p_link_ref),''),
     v_hours, v_due,
     now() + ((v_due - now()) * (select nudge_at_fraction from public.partner_ticket_config where id = 1)),
     now(), v_side)
  returning id into v_id;

  -- The opening message is the body, and the promise is written INTO the
  -- timeline so both sides read the same clock.
  if coalesce(btrim(p_body),'') <> '' then
    insert into public.partner_ticket_message
      (ticket_id, body, actor_side, actor_id, actor_label, attachments)
    values (v_id, btrim(p_body), v_side, auth.uid(), coalesce(a->>'label',''),
            coalesce(p_attachments,'[]'::jsonb));
  end if;
  insert into public.partner_ticket_message (ticket_id, body, actor_side, actor_label, kind)
  values (v_id,
          public._cf('pt.system_raised', jsonb_build_object(
            'cat', coalesce(public._c(v_cat.label_key), v_cat.code),
            'hours', public._fmt_dur(v_hours * 3600))),
          'system', public._c('pt.side.system'), 'system');

  -- Tell the side that now owns it, on the channel it actually reads.
  begin
    if v_owner = 'partner' then
      perform public.notify_partner('partner_issue_raised', jsonb_build_object(
        'partner_id', v_pid::text, 'zone_id', coalesce(v_zone,0)::text,
        'ref', v_ref, 'subject', btrim(p_subject),
        'category', coalesce(public._c(v_cat.label_key), v_cat.code),
        'due', public._ist_stamp(v_due)));
    else
      perform public.notify('partner_issue_raised', null, jsonb_build_object(
        'partner_id', v_pid::text, 'zone_id', coalesce(v_zone,0)::text,
        'ref', v_ref, 'subject', btrim(p_subject),
        'category', coalesce(public._c(v_cat.label_key), v_cat.code),
        'due', public._ist_stamp(v_due)));
    end if;
  exception when others then null;
  end;

  return jsonb_build_object('ok', true, 'id', v_id::text, 'ref', v_ref,
    'toast', public._cf('pt.raised_toast', jsonb_build_object('ref', v_ref)));
end $$;

-- ── one ticket, with its timeline ───────────────────────────────────────────
create or replace function public.partner_ticket_get(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  a jsonb := public._pt_actor(); v_side text; t public.partner_ticket;
  v_msgs jsonb := '[]'::jsonb; m record; v_row jsonb; v_outs jsonb := '[]'::jsonb; o record;
  v_cat public.partner_ticket_category; v_link jsonb; v_partner text;
begin
  v_side := a->>'side';
  if v_side = '' then
    return jsonb_build_object('ok', false, 'message', public._c('pt.err_not_partner'));
  end if;
  select * into t from public.partner_ticket where id = p_id;
  if t.id is null then
    return jsonb_build_object('ok', false, 'message', public._c('pt.err_no_ticket'));
  end if;
  -- Zone scope, enforced on the ONE read every surface goes through.
  if v_side = 'partner' and t.partner_id is distinct from (a->>'partner_id')::bigint then
    return jsonb_build_object('ok', false, 'message', public._c('pt.err_not_yours'));
  end if;

  select * into v_cat from public.partner_ticket_category where code = t.category_code;
  select rp.partner_name into v_partner from public.region_partners rp where rp.id = t.partner_id;
  v_row := public._pt_row(t, v_side);

  for m in select * from public.partner_ticket_message
            where ticket_id = t.id order by created_at loop
    v_msgs := v_msgs || jsonb_build_array(jsonb_build_object(
      'id', m.id::text,
      'body', m.body,
      'side', m.actor_side,
      'kind', m.kind,
      'actor_label', case when m.actor_side = v_side and m.kind = 'message'
                          then public._c('pt.you') else m.actor_label end,
      'when_label', public._ist_stamp(m.created_at),
      'mine', (m.actor_side = v_side and m.kind = 'message'),
      'is_system', (m.actor_side = 'system'),
      'attachments', coalesce(m.attachments,'[]'::jsonb),
      'attach_cta', public._c('pt.attach_open')));
  end loop;

  -- The linked object, resolved to a label the screen prints and a handle it
  -- opens. 'none' means the block is absent, never an empty row.
  if t.link_kind <> 'none' and coalesce(t.link_ref,'') <> '' then
    v_link := jsonb_build_object(
      'has', true, 'kind', t.link_kind, 'ref', t.link_ref,
      'label', case t.link_kind
                 when 'order' then public._cf('pt.link.order', jsonb_build_object('ref', t.link_ref))
                 when 'supplier' then public._c('pt.link.supplier')
                 else public._c('pt.link.settlement') end,
      'cta', public._c('pt.link_cta'));
  else
    v_link := jsonb_build_object('has', false);
  end if;

  for o in select * from public.partner_ticket_outcome
            where active and applies_to in ('all', v_side) order by sort_order loop
    v_outs := v_outs || jsonb_build_array(jsonb_build_object(
      'code', o.code, 'label', coalesce(public._c(o.label_key), o.code)));
  end loop;

  return jsonb_build_object(
    'ok', true, 'side', v_side, 'row', v_row,
    'id', t.id::text, 'ref', coalesce(t.ref,''), 'subject', t.subject,
    'raised_line', public._cf('pt.raised_line', jsonb_build_object(
      'who', case when t.raised_side = 'medibo' then public._c('pt.owner.medibo')
                  else coalesce(nullif(v_partner,''), public._c('pt.owner.partner')) end,
      'when', public._ist_stamp(t.created_at))),
    'timeline_title', public._c('pt.timeline_title'),
    'messages', v_msgs,
    'link', v_link,
    'can_reply', (t.status <> 'closed'),
    'upload', jsonb_build_object(
      'bucket', 'partner-issue-files',
      'folder', 'p' || t.partner_id::text || '/' || t.id::text,
      'cta', public._c('pt.attach_cta')),
    'compose_hint', public._c('pt.compose_hint'),
    'send_cta', public._c('pt.send_cta'),
    'attach_cta', public._c('pt.attach_cta'),
    -- Closing belongs to the side that RAISED it (they say whether it is
    -- solved) and to the office, which owns the register either way.
    'can_close', (t.status <> 'closed' and (v_side = 'medibo' or t.raised_side = v_side)),
    'close', jsonb_build_object(
      'cta', public._c('pt.close_cta'),
      'title', public._c('pt.close_title'),
      'hint', public._c('pt.close_hint'),
      'note_hint', public._c('pt.close_note_hint'),
      'submit', public._c('pt.close_submit'),
      'outcomes', v_outs),
    'closed_line', case when t.status = 'closed'
      then public._cf('pt.closed_line', jsonb_build_object(
             'when', public._ist_stamp(t.closed_at),
             'outcome', coalesce((select public._c(x.label_key) from public.partner_ticket_outcome x
                                   where x.code = t.outcome_code), coalesce(t.outcome_code,''))))
      else '' end);
end $$;

-- ── reply ───────────────────────────────────────────────────────────────────
-- A reply from the side that OWNS it hands the ball back and stops that side's
-- clock; a reply from the other side re-starts it. The status word both sides
-- read is derived from owner_side, never written by a client.
create or replace function public.partner_ticket_reply(
  p_id uuid, p_body text, p_attachments jsonb default '[]'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a jsonb := public._pt_actor(); v_side text; t public.partner_ticket; v_due timestamptz;
begin
  v_side := a->>'side';
  if v_side = '' then
    return jsonb_build_object('ok', false, 'message', public._c('pt.err_not_partner'));
  end if;
  if coalesce(btrim(p_body),'') = '' and coalesce(jsonb_array_length(p_attachments),0) = 0 then
    return jsonb_build_object('ok', false, 'message', public._c('pt.err_empty'));
  end if;
  select * into t from public.partner_ticket where id = p_id;
  if t.id is null then
    return jsonb_build_object('ok', false, 'message', public._c('pt.err_no_ticket'));
  end if;
  if v_side = 'partner' and t.partner_id is distinct from (a->>'partner_id')::bigint then
    return jsonb_build_object('ok', false, 'message', public._c('pt.err_not_yours'));
  end if;
  if t.status = 'closed' then
    return jsonb_build_object('ok', false, 'message', public._c('pt.err_closed'));
  end if;

  insert into public.partner_ticket_message
    (ticket_id, body, actor_side, actor_id, actor_label, attachments)
  values (t.id, btrim(p_body), v_side, auth.uid(), coalesce(a->>'label',''),
          coalesce(p_attachments,'[]'::jsonb));

  if t.owner_side = v_side then
    -- The owner answered: the ball, and the clock, move to the other side.
    v_due := public._pt_due(now(), t.sla_hours);
    update public.partner_ticket
       set owner_side     = case when v_side = 'partner' then 'medibo' else 'partner' end,
           status         = 'waiting',
           first_reply_at = coalesce(first_reply_at, now()),
           sla_due_at     = v_due,
           nudge_due_at   = now() + ((v_due - now())
                              * (select nudge_at_fraction from public.partner_ticket_config where id = 1)),
           nudged_at      = null,
           breached_at    = null,
           last_message_at= now(), last_actor_side = v_side, updated_at = now()
     where id = t.id;
  else
    update public.partner_ticket
       set status = 'open', last_message_at = now(), last_actor_side = v_side, updated_at = now()
     where id = t.id;
  end if;

  return jsonb_build_object('ok', true, 'toast', public._c('pt.sent_toast'));
end $$;

-- ── close ───────────────────────────────────────────────────────────────────
-- The outcome code is REQUIRED, and it is the reason this channel is worth
-- more than a WhatsApp thread: it is what the partner scorecard counts.
create or replace function public.partner_ticket_close(
  p_id uuid, p_outcome_code text, p_note text default '')
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  a jsonb := public._pt_actor(); v_side text; t public.partner_ticket;
  o public.partner_ticket_outcome; v_cfg public.partner_ticket_config;
begin
  v_side := a->>'side';
  if v_side = '' then
    return jsonb_build_object('ok', false, 'message', public._c('pt.err_not_partner'));
  end if;
  select * into t from public.partner_ticket where id = p_id;
  if t.id is null then
    return jsonb_build_object('ok', false, 'message', public._c('pt.err_no_ticket'));
  end if;
  if v_side = 'partner' and t.partner_id is distinct from (a->>'partner_id')::bigint then
    return jsonb_build_object('ok', false, 'message', public._c('pt.err_not_yours'));
  end if;
  if t.status = 'closed' then
    return jsonb_build_object('ok', false, 'message', public._c('pt.err_closed'));
  end if;
  select * into o from public.partner_ticket_outcome
   where code = coalesce(nullif(btrim(p_outcome_code),''),'') and active;
  if o.code is null then
    return jsonb_build_object('ok', false, 'message', public._c('pt.err_no_outcome'));
  end if;
  select * into v_cfg from public.partner_ticket_config where id = 1;

  update public.partner_ticket
     set status = 'closed', closed_at = now(), closed_by = auth.uid(), closed_side = v_side,
         resolved_at = coalesce(resolved_at, now()),
         outcome_code = o.code, outcome_note = coalesce(btrim(p_note),''),
         last_message_at = now(), last_actor_side = v_side, updated_at = now()
   where id = t.id;

  insert into public.partner_ticket_message (ticket_id, body, actor_side, actor_label, kind)
  values (t.id,
          public._cf('pt.system_closed', jsonb_build_object(
            'outcome', coalesce(public._c(o.label_key), o.code)))
          || case when coalesce(btrim(p_note),'') <> '' then ' ' || btrim(p_note) else '' end,
          'system', public._c('pt.side.system'), 'close');

  -- The scorecard feed, in the vocabulary #690/#693 already share: one row per
  -- closed issue, weighted by the outcome, attributed to the partner.
  if v_cfg.scorecard_feed then
    begin
      insert into public.exception_scorecard_input
        (subject_kind, subject_key, reason_code, outcome_code, weight,
         exception_id, zone_id, closed_at, closed_by)
      values ('partner', t.partner_id::text, 'partner_ticket', o.code,
              case when o.fault_side = 'partner' then o.weight else 0 end,
              'partner_ticket:' || t.id::text, t.zone_id::smallint, now(), v_side);
    exception when others then null;
    end;
  end if;

  return jsonb_build_object('ok', true, 'toast', public._c('pt.closed_toast'));
end $$;

-- ── the nav badge: what THIS caller owes an answer on ───────────────────────
create or replace function public._pt_badge_count()
returns integer language plpgsql stable security definer set search_path to 'public' as $$
declare a jsonb := public._pt_actor(); v_side text; v_pid bigint; v_n int := 0;
begin
  v_side := a->>'side';
  if v_side = '' then return 0; end if;
  v_pid := (a->>'partner_id')::bigint;
  select count(*) into v_n from public.partner_ticket t
   where t.status <> 'closed' and t.owner_side = v_side
     and (v_pid is null or t.partner_id = v_pid);
  return coalesce(v_n,0);
end $$;

grant execute on function public.partner_ticket_list(text, bigint)        to authenticated;
grant execute on function public.partner_ticket_new()                     to authenticated;
grant execute on function public.partner_ticket_raise(text, text, text, text, bigint, text, text, jsonb) to authenticated;
grant execute on function public.partner_ticket_get(uuid)                 to authenticated;
grant execute on function public.partner_ticket_reply(uuid, text, jsonb)  to authenticated;
grant execute on function public.partner_ticket_close(uuid, text, text)   to authenticated;
grant execute on function public._pt_badge_count()                        to authenticated;
