-- CHANGE #402 (3 of 3) — SUPPLIER BANK / UPI SELF-SERVICE.
--
-- Payout details lived nowhere: `supplier_payments` carried a payee_name and a
-- payee_vpa TYPED BY THE PERSON RECORDING THE PAYMENT, once per payment, with
-- no record of where they came from and nothing to check them against.
--
-- This is an APPEND-ONLY ledger of payout details instead. A supplier submits a
-- new set; it lands `pending`; an admin approves it; only then does the previous
-- ACTIVE row become `superseded` and the new one `active`. Nothing is ever
-- overwritten, so "what did we pay into in July" stays answerable forever.
--
-- Verification is penny-drop-free by design: the backend scores the submitted
-- account name against the names already on the supplier's profile and prints
-- the verdict for the admin to read. No rupee is moved to check a name.
--
-- Every statement is idempotent — a resumed worker re-applies it silently.

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. THE LEDGER
-- ═══════════════════════════════════════════════════════════════════════════

create table if not exists public.supplier_payout_details (
  id             bigserial primary key,
  supplier_id    uuid not null references public.supplier_profiles(id) on delete cascade,
  account_name   text,
  account_number text,
  ifsc           text,
  bank_name      text,
  upi_vpa        text,
  status         text not null default 'pending'
                   check (status in ('pending','active','rejected','superseded')),
  name_match     text,      -- 'exact' | 'close' | 'differs' | 'unknown'
  name_score     int,
  submitted_by   text,
  submitted_user_id uuid,
  submitted_supplier_user_id bigint references public.supplier_users(id) on delete set null,
  submitted_at   timestamptz not null default now(),
  reviewed_by    text,
  reviewed_at    timestamptz,
  review_note    text
);

create index if not exists supplier_payout_details_supplier_idx
  on public.supplier_payout_details (supplier_id, submitted_at desc);

-- At most ONE active and at most ONE pending set per supplier. The uniqueness
-- is the rule; the RPCs below never have to remember it.
create unique index if not exists supplier_payout_details_one_active
  on public.supplier_payout_details (supplier_id) where status = 'active';
create unique index if not exists supplier_payout_details_one_pending
  on public.supplier_payout_details (supplier_id) where status = 'pending';

alter table public.supplier_payout_details enable row level security;
drop policy if exists supplier_payout_details_admin on public.supplier_payout_details;
create policy supplier_payout_details_admin on public.supplier_payout_details
  for all using (public.role_for_medibo_only() in ('admin','super_admin'))
  with check (public.role_for_medibo_only() in ('admin','super_admin'));

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. PENNY-DROP-FREE VERIFICATION — score the name, move no money
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public._sup_name_key(p text)
returns text language sql immutable as $function$
  select btrim(regexp_replace(
           regexp_replace(lower(coalesce(p,'')),
             '\m(m/s|ms|messrs|pvt|private|ltd|limited|llp|inc|co|company|and|the|medical|surgical|pharma|pharmacy|agencies|agency|enterprises|enterprise|distributors|distributor|traders|trading|store|stores)\M',
             ' ', 'g'),
           '[^a-z0-9]+', ' ', 'g'))
$function$;

-- 0..100 against every name the account already carries. The best match wins,
-- because a proprietor's own name on the bank account is a legitimate match to
-- the contact person even when the firm name differs.
create or replace function public.supplier_name_match(p_supplier uuid, p_account_name text)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare sp record; v_key text; v_best numeric := 0; v_cand text; v_band text;
begin
  select * into sp from supplier_profiles where id = p_supplier;
  v_key := public._sup_name_key(p_account_name);
  if sp.id is null or v_key = '' then
    return jsonb_build_object('band','unknown','score',0,
      'label', public.ui_text('supplier_payout.match_unknown'), 'tone','warning');
  end if;

  foreach v_cand in array array[
      coalesce(sp.supplier_name,''), coalesce(sp.contact_person,''),
      coalesce(sp.contact_name,''),  coalesce(sp.payment_address,'')]
  loop
    if public._sup_name_key(v_cand) <> '' then
      v_best := greatest(v_best, similarity(v_key, public._sup_name_key(v_cand)));
    end if;
  end loop;

  v_band := case when v_best >= 0.85 then 'exact'
                 when v_best >= 0.45 then 'close'
                 else 'differs' end;

  return jsonb_build_object(
    'band', v_band,
    'score', round(v_best * 100)::int,
    'label', replace(public.ui_text('supplier_payout.match_' || v_band),
                     '{name}', coalesce(sp.supplier_name,'')),
    'tone', case v_band when 'exact' then 'success'
                        when 'close' then 'warning' else 'danger' end);
end $function$;

-- Never print a full account number back to a screen.
create or replace function public._sup_mask_acc(p text)
returns text language sql immutable as $function$
  select case when coalesce(btrim(p),'') = '' then ''
              when length(btrim(p)) <= 4 then repeat('•', length(btrim(p)))
              else repeat('•', greatest(length(btrim(p)) - 4, 2)) || right(btrim(p), 4) end
$function$;

-- One row, rendered. Every string here is the backend's.
create or replace function public._sup_payout_block(p_id bigint)
returns jsonb
language sql stable security definer set search_path to 'public'
as $function$
  select jsonb_build_object(
    'id', p_row.id,
    'status', p_row.status,
    'status_label', public.ui_text('supplier_payout.status_' || p_row.status),
    'status_tone', case p_row.status when 'active' then 'success'
                                     when 'pending' then 'warning'
                                     when 'rejected' then 'danger' else 'neutral' end,
    'account_name', coalesce(p_row.account_name,''),
    'account_number_masked', public._sup_mask_acc(p_row.account_number),
    'ifsc', coalesce(p_row.ifsc,''),
    'bank_name', coalesce(p_row.bank_name,''),
    'upi_vpa', coalesce(p_row.upi_vpa,''),
    'match_label', coalesce(public.ui_text('supplier_payout.match_' || coalesce(p_row.name_match,'unknown')),''),
    'match_tone', case coalesce(p_row.name_match,'unknown')
                    when 'exact' then 'success' when 'close' then 'warning'
                    when 'differs' then 'danger' else 'warning' end,
    'submitted_label', replace(replace(public.ui_text('supplier_payout.submitted_on'),
                        '{date}', ist_fmt(p_row.submitted_at,'dmyhm')),
                        '{who}', coalesce(p_row.submitted_by,'')),
    'reviewed_label', case when p_row.reviewed_at is null then ''
      else replace(replace(public.ui_text('supplier_payout.reviewed_on'),
             '{date}', ist_fmt(p_row.reviewed_at,'dmyhm')),
             '{who}', coalesce(p_row.reviewed_by,'')) end,
    'review_note', coalesce(p_row.review_note,''))
  from supplier_payout_details p_row where p_row.id = p_id
$function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. THE SUPPLIER'S OWN PAYOUT SCREEN
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.supplier_payout_get()
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare v_sid uuid := public.my_supplier_id();
        v_active supplier_payout_details%rowtype;
        v_pending supplier_payout_details%rowtype;
begin
  if v_sid is null or not public.supplier_can('supplier.payouts','read') then
    return jsonb_build_object('ok', false, 'error', 'not_authorized', 'tone', 'danger',
      'message', public.ui_text('supplier_payout.err_not_authorized'));
  end if;
  select * into v_active  from supplier_payout_details where supplier_id = v_sid and status = 'active';
  select * into v_pending from supplier_payout_details where supplier_id = v_sid and status = 'pending';

  return jsonb_build_object(
    'ok', true,
    'title', public.ui_text('supplier_payout.title'),
    'subtitle', public.ui_text('supplier_payout.subtitle'),
    'can_edit', public.supplier_can('supplier.payouts','write'),
    'readonly_note', case when public.supplier_can('supplier.payouts','write') then ''
                          else public.ui_text('supplier_payout.readonly_note') end,
    'active_heading', public.ui_text('supplier_payout.active_heading'),
    'pending_heading', public.ui_text('supplier_payout.pending_heading'),
    'history_heading', public.ui_text('supplier_payout.history_heading'),
    'history_empty', public.ui_text('supplier_payout.history_empty'),
    'empty', public.ui_text('supplier_payout.empty'),
    'pending_note', public.ui_text('supplier_payout.pending_note'),
    'submit_label', public.ui_text('supplier_payout.submit_label'),
    'form_heading', public.ui_text('supplier_payout.form_heading'),
    'fields', jsonb_build_array(
      jsonb_build_object('key','account_name',  'label', public.ui_text('supplier_payout.f_account_name'),  'hint', public.ui_text('supplier_payout.h_account_name'),  'required', true),
      jsonb_build_object('key','account_number','label', public.ui_text('supplier_payout.f_account_number'),'hint', public.ui_text('supplier_payout.h_account_number'),'required', false),
      jsonb_build_object('key','ifsc',          'label', public.ui_text('supplier_payout.f_ifsc'),          'hint', public.ui_text('supplier_payout.h_ifsc'),          'required', false),
      jsonb_build_object('key','bank_name',     'label', public.ui_text('supplier_payout.f_bank_name'),     'hint', public.ui_text('supplier_payout.h_bank_name'),     'required', false),
      jsonb_build_object('key','upi_vpa',       'label', public.ui_text('supplier_payout.f_upi_vpa'),       'hint', public.ui_text('supplier_payout.h_upi_vpa'),       'required', false)),
    'active',  public._sup_payout_block(v_active.id),
    'pending', public._sup_payout_block(v_pending.id),
    'history', coalesce((
      select jsonb_agg(public._sup_payout_block(h.id) order by h.submitted_at desc)
        from supplier_payout_details h
       where h.supplier_id = v_sid and h.status in ('superseded','rejected')), '[]'::jsonb));
end $function$;

create or replace function public.supplier_payout_submit(
  p_account_name text, p_account_number text default null, p_ifsc text default null,
  p_bank_name text default null, p_upi_vpa text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare v_sid uuid := public.my_supplier_id(); v_match jsonb; v_id bigint;
        v_acc text; v_ifsc text; v_vpa text; v_name text; v_actor jsonb; sp record;
begin
  if v_sid is null or not public.supplier_can('supplier.payouts','write') then
    return jsonb_build_object('ok',false,'error','not_authorized','tone','danger',
      'message', public.ui_text('supplier_payout.err_not_authorized'));
  end if;

  v_name := nullif(btrim(coalesce(p_account_name,'')),'');
  v_acc  := nullif(regexp_replace(coalesce(p_account_number,''), '\s', '', 'g'), '');
  v_ifsc := nullif(upper(regexp_replace(coalesce(p_ifsc,''), '\s', '', 'g')), '');
  v_vpa  := nullif(lower(btrim(coalesce(p_upi_vpa,''))), '');

  if v_name is null then
    return jsonb_build_object('ok',false,'error','name_required','tone','danger',
      'message', public.ui_text('supplier_payout.err_name_required'));
  end if;
  if v_acc is null and v_vpa is null then
    return jsonb_build_object('ok',false,'error','nothing_to_pay_into','tone','danger',
      'message', public.ui_text('supplier_payout.err_need_one'));
  end if;
  if v_acc is not null and v_acc !~ '^[0-9]{9,18}$' then
    return jsonb_build_object('ok',false,'error','bad_account','tone','danger',
      'message', public.ui_text('supplier_payout.err_bad_account'));
  end if;
  if v_acc is not null and (v_ifsc is null or v_ifsc !~ '^[A-Z]{4}0[A-Z0-9]{6}$') then
    return jsonb_build_object('ok',false,'error','bad_ifsc','tone','danger',
      'message', public.ui_text('supplier_payout.err_bad_ifsc'));
  end if;
  if v_vpa is not null and v_vpa !~ '^[a-z0-9._-]{2,64}@[a-z]{2,64}$' then
    return jsonb_build_object('ok',false,'error','bad_vpa','tone','danger',
      'message', public.ui_text('supplier_payout.err_bad_vpa'));
  end if;

  -- A second pending submission REPLACES the first (it was never live), so the
  -- supplier can fix a typo. An ACTIVE row is never touched here — only an
  -- admin approval can retire it.
  delete from supplier_payout_details where supplier_id = v_sid and status = 'pending';

  v_match := public.supplier_name_match(v_sid, v_name);
  v_actor := public.my_supplier_actor();

  insert into supplier_payout_details(supplier_id, account_name, account_number, ifsc,
    bank_name, upi_vpa, status, name_match, name_score, submitted_by, submitted_user_id,
    submitted_supplier_user_id)
  values (v_sid, v_name, v_acc, v_ifsc, nullif(btrim(coalesce(p_bank_name,'')),''), v_vpa,
          'pending', v_match->>'band', (v_match->>'score')::int,
          v_actor->>'name', auth.uid(), public.my_supplier_user_id())
  returning id into v_id;

  perform public.supplier_audit('supplier.payouts','payout_submitted',
    jsonb_build_object('payout_id', v_id, 'match', v_match->>'band',
      'summary', replace(public.ui_text('supplier_payout.audit_submitted'),
                         '{who}', v_actor->>'name')));

  -- Admin notification: an inbox row per admin. channel='inbox' so the email
  -- trigger on notification_log returns without sending anything, and NOTHING
  -- is ever sent to the supplier from here.
  select * into sp from supplier_profiles where id = v_sid;
  insert into notification_log(event_key, recipient, channel, status, ok, audience,
                               user_id, title, body, language, payload)
  select 'supplier_payout_change', lower(btrim(a.email)), 'inbox', 'delivered', true, 'admin',
         au.id,
         public.ui_text('supplier_payout.notify_title'),
         replace(replace(public.ui_text('supplier_payout.notify_body'),
           '{supplier}', coalesce(sp.supplier_name,'')), '{who}', coalesce(v_actor->>'name','')),
         'en',
         jsonb_build_object('supplier_id', v_sid, 'payout_id', v_id, 'route_key','supplier_accounts')
    from admins a
    left join auth.users au on lower(btrim(au.email)) = lower(btrim(a.email))
   where coalesce(a.email,'') <> '';

  return jsonb_build_object('ok',true,'id',v_id,'tone','success',
    'message', public.ui_text('supplier_payout.submitted'),
    'match', v_match);
exception when others then
  return jsonb_build_object('ok',false,'error','exception','tone','danger',
    'message', replace(public.ui_text('supplier_payout.err_failed'), '{detail}', SQLERRM),
    'sqlstate', SQLSTATE);
end $function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 4. THE ADMIN REVIEW — nothing takes effect before this
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.admin_supplier_payout_queue()
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
begin
  if not (public.is_admin() or public.get_my_role() in ('admin','super_admin')) then
    return jsonb_build_object('ok', false, 'error', 'not_authorized', 'tone', 'danger',
      'message', public.ui_text('supplier_payout.err_not_authorized'));
  end if;
  return jsonb_build_object(
    'ok', true,
    'title', public.ui_text('admin_payout.title'),
    'subtitle', public.ui_text('admin_payout.subtitle'),
    'empty', public.ui_text('admin_payout.empty'),
    'approve_label', public.ui_text('admin_payout.approve'),
    'reject_label', public.ui_text('admin_payout.reject'),
    'note_hint', public.ui_text('admin_payout.note_hint'),
    'current_heading', public.ui_text('admin_payout.current_heading'),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
               'supplier_id', d.supplier_id,
               'supplier_name', sp.supplier_name,
               'pending', public._sup_payout_block(d.id),
               'current', public._sup_payout_block(cur.id))
             order by d.submitted_at)
        from supplier_payout_details d
        join supplier_profiles sp on sp.id = d.supplier_id
        left join lateral (select * from supplier_payout_details a
                            where a.supplier_id = d.supplier_id and a.status='active') cur on true
       where d.status = 'pending'), '[]'::jsonb));
end $function$;

create or replace function public.admin_supplier_payout_review(
  p_id bigint, p_decision text, p_note text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare d supplier_payout_details%rowtype; v_who text := coalesce(public.my_login_email(),'admin');
begin
  if not (public.is_admin() or public.get_my_role() in ('admin','super_admin')) then
    return jsonb_build_object('ok', false, 'error', 'not_authorized', 'tone', 'danger',
      'message', public.ui_text('supplier_payout.err_not_authorized'));
  end if;
  select * into d from supplier_payout_details where id = p_id;
  if d.id is null or d.status <> 'pending' then
    return jsonb_build_object('ok', false, 'error', 'not_pending', 'tone', 'danger',
      'message', public.ui_text('admin_payout.err_not_pending'));
  end if;
  if coalesce(p_decision,'') not in ('approve','reject') then
    return jsonb_build_object('ok', false, 'error', 'bad_decision', 'tone', 'danger',
      'message', public.ui_text('admin_payout.err_bad_decision'));
  end if;

  if p_decision = 'approve' then
    -- The old ACTIVE row is retired, never edited: it stays readable forever,
    -- which is the whole point of the history.
    update supplier_payout_details
       set status = 'superseded', reviewed_by = v_who, reviewed_at = now()
     where supplier_id = d.supplier_id and status = 'active';
    update supplier_payout_details
       set status = 'active', reviewed_by = v_who, reviewed_at = now(),
           review_note = nullif(btrim(coalesce(p_note,'')),'')
     where id = p_id;
  else
    update supplier_payout_details
       set status = 'rejected', reviewed_by = v_who, reviewed_at = now(),
           review_note = nullif(btrim(coalesce(p_note,'')),'')
     where id = p_id;
  end if;

  insert into supplier_audit_log(supplier_id, actor_identity, actor_name, user_id,
                                 feature_key, action, detail)
  values (d.supplier_id, v_who, v_who, auth.uid(), 'supplier.payouts',
          'payout_' || p_decision || 'd',
          jsonb_build_object('payout_id', p_id,
            'summary', replace(public.ui_text('supplier_payout.audit_' || p_decision), '{who}', v_who)));

  return jsonb_build_object('ok', true, 'tone', 'success',
    'message', public.ui_text('admin_payout.' || p_decision || 'd'));
exception when others then
  return jsonb_build_object('ok', false, 'error', 'exception', 'tone', 'danger',
    'message', replace(public.ui_text('supplier_payout.err_failed'), '{detail}', SQLERRM),
    'sqlstate', SQLSTATE);
end $function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 5. THE ACTIVE DETAIL IS WHAT MONEY USES
-- ═══════════════════════════════════════════════════════════════════════════

-- Read by the supplier-payment recording surfaces (admin + partner) and by any
-- future Route payout: one answer to "where does this supplier's money go",
-- carrying the approval that made it the answer.
create or replace function public.supplier_payout_active(p_supplier uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare d supplier_payout_details%rowtype; sp record;
begin
  if not (public.is_admin() or public.get_my_role() in ('admin','super_admin','partner')
          or public.my_supplier_id() = p_supplier) then
    return jsonb_build_object('ok', false, 'error', 'not_authorized', 'has', false);
  end if;
  select * into sp from supplier_profiles where id = p_supplier;
  select * into d from supplier_payout_details
   where supplier_id = p_supplier and status = 'active';
  if d.id is null then
    return jsonb_build_object('ok', true, 'has', false,
      'label', public.ui_text('admin_payout.none_on_file'),
      'tone', 'warning', 'payee_name', coalesce(sp.supplier_name,''), 'payee_vpa', '');
  end if;
  return jsonb_build_object('ok', true, 'has', true,
    'label', public.ui_text('admin_payout.on_file'),
    'tone', 'success',
    'payee_name', coalesce(d.account_name, sp.supplier_name, ''),
    'payee_vpa', coalesce(d.upi_vpa,''),
    'detail', public._sup_payout_block(d.id));
end $function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 6. ONE PREFERENCE DRIVES BOTH SURFACES
-- ═══════════════════════════════════════════════════════════════════════════

-- The notification stack already resolved a per-user language from
-- pharmacy_profiles.wa_language. #402 adds an explicit preference the user sets
-- themselves; it OUTRANKS the inferred one, so switching the app to Hindi also
-- switches the messages — one switch, not two.
create or replace function public.notif_language_for(p_user_id uuid default null::uuid,
                                                     p_phone text default null::text,
                                                     p_email text default null::text)
returns text
language plpgsql stable security definer set search_path to 'public'
as $function$
declare v text;
begin
  -- CHANGE #402 — the explicit per-user choice wins over anything inferred.
  select lp.lang into v from user_language_pref lp
    join app_language al on al.code = lp.lang and al.is_active
   where (p_user_id is not null and lp.user_id = p_user_id)
      or (p_email is not null and p_email <> '' and lp.user_id =
            (select u.id from auth.users u where lower(btrim(u.email)) = lower(btrim(p_email)) limit 1))
   limit 1;
  if v is not null and v <> '' then return public.notif_norm_lang(v); end if;

  select wa_language into v from pharmacy_profiles
   where (p_user_id is not null and user_id = p_user_id)
      or (p_phone   is not null and p_phone <> '' and right(regexp_replace(coalesce(phone,''),'\D','','g'),10) = right(regexp_replace(p_phone,'\D','','g'),10))
      or (p_email   is not null and p_email <> '' and lower(coalesce(email,'')) = lower(p_email))
   order by (user_id = p_user_id) desc nulls last
   limit 1;
  if v is null or v = '' then
    select default_language into v from notification_email_config where id = 'singleton';
  end if;
  return public.notif_norm_lang(v);
end $function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 7. GRANTS
-- ═══════════════════════════════════════════════════════════════════════════

do $g$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('supplier_payout_get','supplier_payout_submit',
                         'supplier_payout_active','supplier_name_match',
                         'admin_supplier_payout_queue','admin_supplier_payout_review',
                         '_sup_payout_block','_sup_mask_acc','_sup_name_key')
  loop
    execute format('revoke all on function %s from public, anon', r.sig);
    execute format('grant execute on function %s to authenticated, service_role', r.sig);
  end loop;
end $g$;
