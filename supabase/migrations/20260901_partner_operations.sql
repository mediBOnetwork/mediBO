-- CHANGE #400 — Partner operations: worker management, settlement acknowledge,
-- next-zone onboarding.
--
-- Idempotent by construction: every table is `if not exists`, every column is
-- `add column if not exists`, every seed is `on conflict do update`, and every
-- function is `create or replace`. A resumed worker re-applying this file is a
-- silent no-op.
--
-- Written from the LIVE definitions after each part was proven against real
-- data as a real partner staff login and a real admin (all rollback-scoped).

-- ── 1. tables ──────────────────────────────────────────────────────────────
create table if not exists public.partner_ops_label(
  key text primary key,
  label text not null,
  updated_at timestamptz not null default now());

create table if not exists public.partner_worker(
  id            bigserial primary key,
  partner_id    bigint not null references public.region_partners(id) on delete cascade,
  zone_id       smallint,
  identity      text unique,
  display_name  text,
  work_role     text not null default 'both',
  is_active     boolean not null default true,
  created_by    text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now());
create index if not exists partner_worker_partner_idx on public.partner_worker(partner_id) where is_active;

create table if not exists public.partner_worker_shift(
  id          bigserial primary key,
  worker_id   bigint not null references public.partner_worker(id) on delete cascade,
  shift_date  date not null,
  status      text not null,
  marked_by   text,
  marked_at   timestamptz not null default now(),
  unique (worker_id, shift_date));

create table if not exists public.partner_settlement_ack(
  period_id    bigint primary key references public.partner_settlement_periods(id) on delete cascade,
  partner_id   bigint not null,
  state        text   not null,
  note         text,
  by_identity  text,
  by_partner_user bigint,
  acked_at     timestamptz not null default now(),
  resolved_at  timestamptz,
  resolved_by  text,
  resolve_note text);

create table if not exists public.partner_onboarding_step(
  step_key   text primary key,
  label      text not null,
  hint       text,
  kind       text not null default 'doc',
  is_required boolean not null default true,
  sort_order int not null default 100,
  is_active  boolean not null default true);

create table if not exists public.partner_onboarding_state(
  partner_id bigint not null references public.region_partners(id) on delete cascade,
  step_key   text   not null references public.partner_onboarding_step(step_key) on delete cascade,
  done       boolean not null default false,
  value      text,
  doc_path   text,
  updated_at timestamptz not null default now(),
  updated_by text,
  primary key (partner_id, step_key));

-- Settlement reads bank/UPI off the partner row, so that is where they live.
alter table public.region_partners add column if not exists bank_account text;
alter table public.region_partners add column if not exists bank_ifsc    text;
alter table public.region_partners add column if not exists bank_name     text;
alter table public.region_partners add column if not exists upi_id        text;
alter table public.region_partners add column if not exists agreement_doc_path text;
alter table public.region_partners add column if not exists activated_at  timestamptz;
alter table public.region_partners add column if not exists activated_by  text;
alter table public.region_partners add column if not exists activation_override_reason text;

-- ── 2. lockdown (every new table, from the first migration) ────────────────
do $lock$
declare t text;
begin
  foreach t in array array['partner_ops_label','partner_worker','partner_worker_shift',
                           'partner_settlement_ack','partner_onboarding_step',
                           'partner_onboarding_state'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force  row level security', t);
    execute format('revoke all on table public.%I from public, anon, authenticated', t);
    execute format('grant all on table public.%I to service_role', t);
  end loop;
end $lock$;

-- ── 3. copy (every display string; change one with an UPDATE, not a deploy) ──
insert into public.partner_ops_label(key,label) values
 ('ack.admin_heading','Partner acknowledgement'),
 ('ack.agree','Agree'),
 ('ack.agreed_toast','Thank you — acknowledgement recorded.'),
 ('ack.by','{who} on {when}'),
 ('ack.dispute','Dispute'),
 ('ack.disputed_toast','Dispute recorded. This period''s payout is on hold.'),
 ('ack.disputed_toast_manual','Dispute recorded. The mediBO team will look at this period.'),
 ('ack.err_bad_state','Choose Agree or Dispute.'),
 ('ack.err_frozen_settle','This period is disputed — resolve the dispute before paying it out.'),
 ('ack.err_no_period','That settlement period does not exist.'),
 ('ack.err_not_authorized','You do not have access to this statement.'),
 ('ack.frozen','Payout frozen while this period is disputed.'),
 ('ack.heading','Do you agree with this statement?'),
 ('ack.hint','Agreeing records your acknowledgement. Disputing freezes only this period''s payout and opens a note for the mediBO team — every other period keeps moving.'),
 ('ack.note_hint','What is wrong with this period? (optional)'),
 ('ack.resolve','Resolve dispute'),
 ('ack.resolved','Dispute resolved by mediBO.'),
 ('ack.state_agreed','Agreed'),
 ('ack.state_disputed','Disputed'),
 ('ack.state_none','Not acknowledged yet'),
 ('ob.activate','Activate partner'),
 ('ob.activated','Partner activated.'),
 ('ob.active','Active'),
 ('ob.complete_label','Complete'),
 ('ob.deactivate','Deactivate partner'),
 ('ob.deactivated','Partner deactivated.'),
 ('ob.err_bad_step','That is not an onboarding item.'),
 ('ob.err_incomplete','Onboarding is not complete. Finish the outstanding items, or activate with an override reason.'),
 ('ob.err_no_partner','That partner does not exist.'),
 ('ob.err_not_authorized','You do not have access to partner onboarding.'),
 ('ob.inactive','Not active'),
 ('ob.intro','Everything a zone partner needs before they can go live. Complete these and the partner can be switched on.'),
 ('ob.not_ready','{n} item(s) still outstanding'),
 ('ob.override_hint','Reason for activating before onboarding is complete'),
 ('ob.override_note','Activated by override: {reason}'),
 ('ob.pending_label','Pending'),
 ('ob.progress','{done} of {total} complete'),
 ('ob.ready','Ready to activate'),
 ('ob.saved','Saved.'),
 ('ob.title','Onboarding'),
 ('wk.add','Add worker'),
 ('wk.added','Worker added.'),
 ('wk.empty','No workers yet. Add the first one and their name will appear on every count they do.'),
 ('wk.err_bad_identity','Enter a valid phone number or email.'),
 ('wk.err_bad_status','That is not an attendance option.'),
 ('wk.err_failed','Could not save: {detail}'),
 ('wk.err_identity_taken','That login already belongs to someone else.'),
 ('wk.err_not_authorized','You do not have access to manage workers.'),
 ('wk.err_not_found','That worker is not in your zone.'),
 ('wk.identity_hint','Phone or email they log in with'),
 ('wk.intro','Your zone''s counting and packing staff. Every voice count and pack action is stamped with the worker you mark on shift.'),
 ('wk.name_hint','Name as it should appear on a count'),
 ('wk.remove','Remove'),
 ('wk.removed','Worker removed.'),
 ('wk.role_both','Counting and packing'),
 ('wk.role_counting','Counting'),
 ('wk.role_label','Does'),
 ('wk.role_packing','Packing'),
 ('wk.shift_absent','Absent'),
 ('wk.shift_half','Half day'),
 ('wk.shift_hint','Tap a worker to mark today''s attendance.'),
 ('wk.shift_present','Present'),
 ('wk.shift_saved','Attendance saved.'),
 ('wk.shift_title','On shift today'),
 ('wk.shift_unmarked','Not marked'),
 ('wk.title','Workers')
on conflict (key) do update set label = excluded.label, updated_at = now();

-- ── 4. the onboarding catalog: a new required item for the next zone is one INSERT ──
insert into public.partner_onboarding_step(step_key,label,hint,kind,is_required,sort_order) values
 ('gst','GSTIN','GST registration number and certificate','doc','t',10),
 ('dl_20b','Drug Licence 20B','Wholesale licence to sell','doc','t',20),
 ('dl_21b','Drug Licence 21B','Wholesale licence to stock','doc','t',30),
 ('agreement','Signed agreement','The countersigned partner agreement PDF','doc','t',40),
 ('bank','Bank / UPI for settlement','Where the monthly payout goes','bank','t',50),
 ('first_login','First staff login','At least one partner login created','auto','t',60),
 ('permissions','Permissions preset','Feature access granted for the zone','auto','t',70)
on conflict (step_key) do update set label=excluded.label, hint=excluded.hint, kind=excluded.kind, is_required=excluded.is_required, sort_order=excluded.sort_order;

-- ── 5. the Workers feature in the registry (partner-eligible, opt-in) ──
insert into public.feature_registry
 (feature_key,label,group_label,icon_key,route_key,sort_order,owner,partner_eligible,
  default_access,is_active,category,surface,deep_link,search_terms)
values
 ('partner.workers','Workers','Partner','people','partner_workers',940,'partner',true,
  'none',true,'system','dashboard','/admin/go/partner_workers',
  'worker staff counting packing shift attendance')
on conflict (feature_key) do update
  set label='Workers', route_key='partner_workers', owner='partner',
      partner_eligible=true, category='system', surface='dashboard', is_active=true;

-- ── 6. functions ──────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._pob_step_done(p_partner_id bigint, p_step text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare rp public.region_partners%rowtype; st public.partner_onboarding_state%rowtype;
begin
  select * into rp from region_partners where id = p_partner_id;
  if not found then return false; end if;
  select * into st from partner_onboarding_state
   where partner_id = p_partner_id and step_key = p_step;

  return case p_step
    when 'gst'        then coalesce(nullif(btrim(coalesce(rp.gstin,'')),''),'') <> ''
                           and coalesce(nullif(btrim(coalesce(rp.gst_doc_path,'')),''),'') <> ''
    when 'dl_20b'     then coalesce(nullif(btrim(coalesce(rp.dl_20b,'')),''),'') <> ''
                           and coalesce(nullif(btrim(coalesce(rp.dl20b_doc_path,'')),''),'') <> ''
    when 'dl_21b'     then coalesce(nullif(btrim(coalesce(rp.dl_21b,'')),''),'') <> ''
                           and coalesce(nullif(btrim(coalesce(rp.dl21b_doc_path,'')),''),'') <> ''
    when 'agreement'  then coalesce(nullif(btrim(coalesce(rp.agreement_doc_path,'')),''),'') <> ''
    when 'bank'       then (coalesce(nullif(btrim(coalesce(rp.upi_id,'')),''),'') <> '')
                        or (coalesce(nullif(btrim(coalesce(rp.bank_account,'')),''),'') <> ''
                            and coalesce(nullif(btrim(coalesce(rp.bank_ifsc,'')),''),'') <> '')
    when 'first_login'then exists (select 1 from partner_users pu
                                    where pu.partner_id = p_partner_id and pu.is_active)
    when 'permissions'then exists (select 1 from partner_permissions pp
                                    where pp.partner_id = p_partner_id and pp.access <> 'none')
    else coalesce(st.done, false)
  end;
end $function$
;

CREATE OR REPLACE FUNCTION public._pop_c(p_key text)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
  select coalesce((select label from public.partner_ops_label where key = p_key), '')
$function$
;

CREATE OR REPLACE FUNCTION public._stl_ack_block(p_period_id bigint, p_is_admin boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare a public.partner_settlement_ack%rowtype; p public.partner_settlement_periods%rowtype;
        v_state text; v_mine boolean;
begin
  select * into p from partner_settlement_periods where id = p_period_id;
  select * into a from partner_settlement_ack     where period_id = p_period_id;
  v_state := coalesce(a.state,'none');
  -- A dispute that mediBO has resolved is no longer a freeze.
  if v_state = 'disputed' and a.resolved_at is not null then v_state := 'resolved'; end if;
  v_mine := (not p_is_admin) and p.partner_id is not distinct from public.my_partner_id();

  return jsonb_build_object(
    'heading',      case when p_is_admin then public._pop_c('ack.admin_heading')
                         else public._pop_c('ack.heading') end,
    'hint',         case when p_is_admin then '' else public._pop_c('ack.hint') end,
    'state',        v_state,
    'state_label',  case v_state
                      when 'agreed'   then public._pop_c('ack.state_agreed')
                      when 'disputed' then public._pop_c('ack.state_disputed')
                      when 'resolved' then public._pop_c('ack.resolved')
                      else public._pop_c('ack.state_none') end,
    'state_tone',   case v_state when 'agreed'   then 'success'
                                 when 'disputed' then 'danger'
                                 when 'resolved' then 'info'
                                 else 'neutral' end,
    'note',         coalesce(a.note,''),
    'by_label',     case when a.acked_at is null then ''
                         else replace(replace(public._pop_c('ack.by'),
                                '{who}',  coalesce(nullif(a.by_identity,''),'')),
                                '{when}', public.ist_fmt(a.acked_at,'dmy')) end,
    -- Only the partner acts; the admin sees the same block read-only.
    'can_act',      v_mine and v_state in ('none','resolved'),
    'agree_label',  public._pop_c('ack.agree'),
    'dispute_label',public._pop_c('ack.dispute'),
    'note_hint',    public._pop_c('ack.note_hint'),
    'can_resolve',  p_is_admin and v_state = 'disputed',
    'resolve_label',public._pop_c('ack.resolve'),
    -- The freeze is a FLAG the payout path reads, not a number it deducts.
    'frozen',       (v_state = 'disputed'),
    'frozen_text',  case when v_state = 'disputed' then public._pop_c('ack.frozen') else '' end);
end $function$
;

CREATE OR REPLACE FUNCTION public.partner_onboarding_get(p_partner_id bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_admin boolean := public.is_admin();
        v_pid bigint := coalesce(case when v_admin then p_partner_id else null end, public.my_partner_id());
        rp public.region_partners%rowtype; v_rows jsonb; v_done int; v_total int; v_missing int;
begin
  if v_pid is null then
    return jsonb_build_object('ok',false,'error','no_partner','tone','danger',
      'message', public._pop_c('ob.err_no_partner'));
  end if;
  if not v_admin and v_pid is distinct from public.my_partner_id() then
    return jsonb_build_object('ok',false,'error','not_authorized','tone','danger',
      'message', public._pop_c('ob.err_not_authorized'));
  end if;
  select * into rp from region_partners where id = v_pid;
  if not found then
    return jsonb_build_object('ok',false,'error','no_partner','tone','danger',
      'message', public._pop_c('ob.err_no_partner'));
  end if;

  select jsonb_agg(jsonb_build_object(
           'step_key', s.step_key, 'label', s.label, 'hint', coalesce(s.hint,''),
           'kind', s.kind, 'required', s.is_required,
           'done', public._pob_step_done(v_pid, s.step_key),
           'status_label', case when public._pob_step_done(v_pid, s.step_key)
                                then public._pop_c('ob.complete_label')
                                else public._pop_c('ob.pending_label') end,
           'status_tone',  case when public._pob_step_done(v_pid, s.step_key)
                                then 'success' else 'warning' end)
         order by s.sort_order)
    into v_rows
    from partner_onboarding_step s where s.is_active;
  v_rows := coalesce(v_rows,'[]'::jsonb);

  select count(*) filter (where (e->>'done')::boolean),
         count(*),
         count(*) filter (where (e->>'required')::boolean and not (e->>'done')::boolean)
    into v_done, v_total, v_missing
    from jsonb_array_elements(v_rows) e;

  return jsonb_build_object(
    'ok', true,
    'partner_id', v_pid,
    'partner_name', coalesce(rp.partner_name,''),
    'zone_id', rp.zone_id,
    'screen_title', public._pop_c('ob.title'),
    'intro', public._pop_c('ob.intro'),
    'is_admin', v_admin,
    'rows', v_rows,
    'done_count', v_done, 'total_count', v_total, 'missing_count', v_missing,
    'progress_label', replace(replace(public._pop_c('ob.progress'),
                        '{done}', v_done::text), '{total}', v_total::text),
    'ready', (v_missing = 0),
    'ready_label', case when v_missing = 0 then public._pop_c('ob.ready')
                        else replace(public._pop_c('ob.not_ready'),'{n}', v_missing::text) end,
    'ready_tone', case when v_missing = 0 then 'success' else 'warning' end,
    'is_active', coalesce(rp.is_active,false),
    'active_label', case when coalesce(rp.is_active,false) then public._pop_c('ob.active')
                         else public._pop_c('ob.inactive') end,
    'active_tone', case when coalesce(rp.is_active,false) then 'success' else 'neutral' end,
    'can_activate', v_admin,
    'activate_label',   public._pop_c('ob.activate'),
    'deactivate_label', public._pop_c('ob.deactivate'),
    'override_hint',    public._pop_c('ob.override_hint'),
    'override_reason',  coalesce(rp.activation_override_reason,''));
end $function$
;

CREATE OR REPLACE FUNCTION public.partner_onboarding_set(p_partner_id bigint, p_step_key text, p_value text DEFAULT NULL::text, p_doc_path text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_admin boolean := public.is_admin();
        v_pid bigint := coalesce(case when v_admin then p_partner_id else null end, public.my_partner_id());
        s public.partner_onboarding_step%rowtype; v text := nullif(btrim(coalesce(p_value,'')),'');
        d text := nullif(btrim(coalesce(p_doc_path,'')),'');
begin
  if not v_admin then
    return jsonb_build_object('ok',false,'error','not_authorized','tone','danger',
      'message', public._pop_c('ob.err_not_authorized'));
  end if;
  if v_pid is null or not exists (select 1 from region_partners where id = v_pid) then
    return jsonb_build_object('ok',false,'error','no_partner','tone','danger',
      'message', public._pop_c('ob.err_no_partner'));
  end if;
  select * into s from partner_onboarding_step where step_key = p_step_key and is_active;
  if not found then
    return jsonb_build_object('ok',false,'error','bad_step','tone','danger',
      'message', public._pop_c('ob.err_bad_step'));
  end if;

  -- Doc/bank items write the PARTNER ROW, because that is where the rest of the
  -- platform already reads them from; the state table only records who and when.
  if p_step_key = 'gst' then
    update region_partners set gstin = coalesce(v, gstin),
           gst_doc_path = coalesce(d, gst_doc_path), updated_at = now() where id = v_pid;
  elsif p_step_key = 'dl_20b' then
    update region_partners set dl_20b = coalesce(v, dl_20b),
           dl20b_doc_path = coalesce(d, dl20b_doc_path), updated_at = now() where id = v_pid;
  elsif p_step_key = 'dl_21b' then
    update region_partners set dl_21b = coalesce(v, dl_21b),
           dl21b_doc_path = coalesce(d, dl21b_doc_path), updated_at = now() where id = v_pid;
  elsif p_step_key = 'agreement' then
    update region_partners set agreement_doc_path = coalesce(d, agreement_doc_path),
           updated_at = now() where id = v_pid;
  elsif p_step_key = 'bank' then
    -- "acct|ifsc|bank name|upi" — one field per positional slot, blanks kept.
    update region_partners
       set bank_account = coalesce(nullif(split_part(coalesce(v,''),'|',1),''), bank_account),
           bank_ifsc    = coalesce(nullif(split_part(coalesce(v,''),'|',2),''), bank_ifsc),
           bank_name    = coalesce(nullif(split_part(coalesce(v,''),'|',3),''), bank_name),
           upi_id       = coalesce(nullif(split_part(coalesce(v,''),'|',4),''), upi_id),
           updated_at = now()
     where id = v_pid;
  end if;

  insert into partner_onboarding_state(partner_id, step_key, done, value, doc_path, updated_by)
  values (v_pid, p_step_key, true, v, d, coalesce(public.my_login_email(),'admin'))
  on conflict (partner_id, step_key) do update
    set done = true, value = coalesce(excluded.value, partner_onboarding_state.value),
        doc_path = coalesce(excluded.doc_path, partner_onboarding_state.doc_path),
        updated_at = now(), updated_by = excluded.updated_by;

  return jsonb_build_object('ok',true,'tone','success',
    'message', public._pop_c('ob.saved'),
    'state', public.partner_onboarding_get(v_pid));
end $function$
;

CREATE OR REPLACE FUNCTION public.partner_set_active(p_partner_id bigint, p_active boolean, p_override_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_state jsonb; v_missing int; v_reason text := nullif(btrim(coalesce(p_override_reason,'')),'');
begin
  if not public.is_admin() then
    return jsonb_build_object('ok',false,'error','not_authorized','tone','danger',
      'message', public._pop_c('ob.err_not_authorized'));
  end if;
  if not exists (select 1 from region_partners where id = p_partner_id) then
    return jsonb_build_object('ok',false,'error','no_partner','tone','danger',
      'message', public._pop_c('ob.err_no_partner'));
  end if;

  if p_active then
    v_state := public.partner_onboarding_get(p_partner_id);
    v_missing := coalesce((v_state->>'missing_count')::int, 0);
    -- The gate: incomplete onboarding blocks activation unless an admin gives a
    -- REASON, which is stored on the row and written to the audit log.
    if v_missing > 0 and v_reason is null then
      return jsonb_build_object('ok',false,'error','onboarding_incomplete','tone','danger',
        'message', public._pop_c('ob.err_incomplete'),
        'missing_count', v_missing, 'state', v_state);
    end if;
  end if;

  update region_partners
     set is_active = p_active,
         activated_at = case when p_active then now() else null end,
         activated_by = case when p_active then coalesce(public.my_login_email(),'admin') else null end,
         activation_override_reason = case when p_active then v_reason else null end,
         updated_at = now()
   where id = p_partner_id;

  insert into partner_audit_log(partner_id, user_id, feature_key, action, detail)
  values (p_partner_id, auth.uid(), 'partner.onboarding',
          case when p_active then 'partner_activated' else 'partner_deactivated' end,
          jsonb_build_object('override_reason', v_reason,
            'missing_count', coalesce(v_missing,0),
            'summary', case when p_active then
                 case when v_reason is null then 'Activated partner ' || p_partner_id
                      else replace(public._pop_c('ob.override_note'),'{reason}', v_reason) end
                 else 'Deactivated partner ' || p_partner_id end));

  return jsonb_build_object('ok',true,'tone','success',
    'message', case when p_active then public._pop_c('ob.activated')
                    else public._pop_c('ob.deactivated') end,
    'state', public.partner_onboarding_get(p_partner_id));
end $function$
;

CREATE OR REPLACE FUNCTION public.partner_worker_add(p_identity text, p_name text DEFAULT NULL::text, p_role text DEFAULT 'both'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_pid bigint := public.my_partner_id(); k text; own record; v_id bigint; v_role text;
begin
  if v_pid is null or not public.partner_can('partner.workers','write') then
    return jsonb_build_object('ok',false,'error','not_authorized','tone','danger',
      'message', public._pop_c('wk.err_not_authorized'));
  end if;
  v_role := lower(btrim(coalesce(p_role,'both')));
  if v_role not in ('counting','packing','both') then v_role := 'both'; end if;
  k := identity_norm(p_identity);
  if k is null then
    return jsonb_build_object('ok',false,'error','bad_identity','tone','danger',
      'message', public._pop_c('wk.err_bad_identity'));
  end if;

  -- Never adopt a login that already belongs to a different owner, or to
  -- another partner's worker. Re-adding your OWN removed worker reactivates.
  select li.owner_type, li.owner_id into own from login_identities li where li.identity = k;
  if own.owner_type is not null and own.owner_type <> 'worker' then
    return jsonb_build_object('ok',false,'error','identity_taken','tone','danger',
      'message', public._pop_c('wk.err_identity_taken'));
  end if;
  if exists (select 1 from partner_worker w where w.identity = k and w.partner_id <> v_pid) then
    return jsonb_build_object('ok',false,'error','identity_taken','tone','danger',
      'message', public._pop_c('wk.err_identity_taken'));
  end if;

  insert into partner_worker(partner_id, zone_id, identity, display_name, work_role, created_by)
  values (v_pid, public.partner_zone_id(), k,
          nullif(btrim(coalesce(p_name,'')),''), v_role,
          coalesce(public.my_login_email(),'partner'))
  on conflict (identity) do update
    set partner_id = excluded.partner_id, is_active = true, work_role = excluded.work_role,
        display_name = coalesce(excluded.display_name, partner_worker.display_name),
        updated_at = now()
  returning id into v_id;

  insert into login_identities(identity, kind, owner_type, owner_id)
  values (k, case when position('@' in k) > 0 then 'email' else 'phone' end, 'worker', v_id::text)
  on conflict (identity) do update set owner_type = 'worker', owner_id = v_id::text;

  perform public.partner_audit('partner.workers','worker_added',
    jsonb_build_object('identity',k,'worker_id',v_id,'role',v_role,'summary','Added worker ' || k));

  return jsonb_build_object('ok',true,'id',v_id,'tone','success',
    'message', public._pop_c('wk.added'), 'state', public.partner_workers_console());
exception when others then
  return jsonb_build_object('ok',false,'error','exception','tone','danger',
    'message', replace(public._pop_c('wk.err_failed'),'{detail}',SQLERRM),'sqlstate',SQLSTATE);
end $function$
;

CREATE OR REPLACE FUNCTION public.partner_worker_remove(p_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_pid bigint := public.my_partner_id(); w record;
begin
  if v_pid is null or not public.partner_can('partner.workers','write') then
    return jsonb_build_object('ok',false,'error','not_authorized','tone','danger',
      'message', public._pop_c('wk.err_not_authorized'));
  end if;
  select * into w from partner_worker where id = p_id and partner_id = v_pid;
  if not found then
    return jsonb_build_object('ok',false,'error','not_found','tone','danger',
      'message', public._pop_c('wk.err_not_found'));
  end if;
  -- Deactivate, never delete: past counts and packs must keep their attribution.
  update partner_worker set is_active = false, updated_at = now() where id = p_id;
  delete from login_identities where identity = w.identity and owner_type = 'worker';
  perform public.partner_audit('partner.workers','worker_removed',
    jsonb_build_object('worker_id',p_id,'identity',w.identity,'summary','Removed worker ' || w.identity));
  return jsonb_build_object('ok',true,'tone','success',
    'message', public._pop_c('wk.removed'), 'state', public.partner_workers_console());
end $function$
;

CREATE OR REPLACE FUNCTION public.partner_worker_shift_set(p_worker_id bigint, p_status text, p_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_pid bigint := public.my_partner_id();
        v_d date := coalesce(p_date, (now() at time zone 'Asia/Kolkata')::date);
begin
  if v_pid is null or not public.partner_can('partner.workers','write') then
    return jsonb_build_object('ok',false,'error','not_authorized','tone','danger',
      'message', public._pop_c('wk.err_not_authorized'));
  end if;
  if p_status not in ('present','absent','half') then
    return jsonb_build_object('ok',false,'error','bad_status','tone','danger',
      'message', public._pop_c('wk.err_bad_status'));
  end if;
  if not exists (select 1 from partner_worker where id = p_worker_id and partner_id = v_pid and is_active) then
    return jsonb_build_object('ok',false,'error','not_found','tone','danger',
      'message', public._pop_c('wk.err_not_found'));
  end if;
  insert into partner_worker_shift(worker_id, shift_date, status, marked_by)
  values (p_worker_id, v_d, p_status, coalesce(public.my_login_email(),'partner'))
  on conflict (worker_id, shift_date) do update
    set status = excluded.status, marked_by = excluded.marked_by, marked_at = now();
  perform public.partner_audit('partner.workers','shift_marked',
    jsonb_build_object('worker_id',p_worker_id,'date',v_d,'status',p_status));
  return jsonb_build_object('ok',true,'tone','success',
    'message', public._pop_c('wk.shift_saved'), 'state', public.partner_workers_console());
end $function$
;

CREATE OR REPLACE FUNCTION public.partner_workers_console()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_pid bigint := public.my_partner_id(); v_today date := (now() at time zone 'Asia/Kolkata')::date;
begin
  if v_pid is null or not public.partner_can('partner.workers','read') then
    return jsonb_build_object('ok',false,'error','not_authorized','tone','danger',
      'message', public._pop_c('wk.err_not_authorized'));
  end if;
  return jsonb_build_object(
    'ok', true,
    'screen_title', public._pop_c('wk.title'),
    'intro',        public._pop_c('wk.intro'),
    'can_write',    public.partner_can('partner.workers','write'),
    'add_label',    public._pop_c('wk.add'),
    'remove_label', public._pop_c('wk.remove'),
    'identity_hint',public._pop_c('wk.identity_hint'),
    'name_hint',    public._pop_c('wk.name_hint'),
    'role_label',   public._pop_c('wk.role_label'),
    'empty_text',   public._pop_c('wk.empty'),
    'shift_title',  public._pop_c('wk.shift_title'),
    'shift_hint',   public._pop_c('wk.shift_hint'),
    'today_label',  public.ist_fmt(v_today::timestamptz,'dmy'),
    -- The role and attendance options are DATA: a new option is one insert.
    'role_options', jsonb_build_array(
       jsonb_build_object('value','counting','label',public._pop_c('wk.role_counting')),
       jsonb_build_object('value','packing', 'label',public._pop_c('wk.role_packing')),
       jsonb_build_object('value','both',    'label',public._pop_c('wk.role_both'))),
    'shift_options', jsonb_build_array(
       jsonb_build_object('value','present','label',public._pop_c('wk.shift_present'),'tone','success'),
       jsonb_build_object('value','half',   'label',public._pop_c('wk.shift_half'),   'tone','warning'),
       jsonb_build_object('value','absent', 'label',public._pop_c('wk.shift_absent'), 'tone','danger')),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', w.id,
               'name', coalesce(nullif(btrim(coalesce(w.display_name,'')),''), w.identity),
               'identity', w.identity,
               'role', w.work_role,
               'role_label', public._pop_c('wk.role_' || w.work_role),
               'shift', coalesce(s.status,''),
               'shift_label', case when s.status is null then public._pop_c('wk.shift_unmarked')
                                   else public._pop_c('wk.shift_' || s.status) end,
               'shift_tone', case s.status when 'present' then 'success'
                                           when 'half'    then 'warning'
                                           when 'absent'  then 'danger'
                                           else 'neutral' end)
             order by lower(coalesce(nullif(btrim(coalesce(w.display_name,'')),''), w.identity)))
        from partner_worker w
        left join partner_worker_shift s on s.worker_id = w.id and s.shift_date = v_today
       where w.partner_id = v_pid and w.is_active), '[]'::jsonb));
end $function$
;

CREATE OR REPLACE FUNCTION public.settlement_ack_resolve(p_period_id bigint, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.is_admin() then
    return jsonb_build_object('ok',false,'error','not_authorized','tone','danger',
      'message', public._pop_c('ack.err_not_authorized'));
  end if;
  update partner_settlement_ack
     set resolved_at = now(), resolved_by = coalesce(public.my_login_email(),'admin'),
         resolve_note = nullif(btrim(coalesce(p_note,'')),'')
   where period_id = p_period_id and state = 'disputed';
  if not found then
    return jsonb_build_object('ok',false,'error','no_period','tone','danger',
      'message', public._pop_c('ack.err_no_period'));
  end if;
  return jsonb_build_object('ok',true,'tone','success',
    'message', public._pop_c('ack.resolved'),
    'ack', public._stl_ack_block(p_period_id, true));
end $function$
;

CREATE OR REPLACE FUNCTION public.settlement_ack_set(p_period_id bigint, p_state text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare p public.partner_settlement_periods%rowtype; v_partner bigint := public.my_partner_id();
        v_mode text; v_msg text;
begin
  if p_state not in ('agreed','disputed') then
    return jsonb_build_object('ok',false,'error','bad_state','tone','danger',
      'message', public._pop_c('ack.err_bad_state'));
  end if;
  select * into p from partner_settlement_periods where id = p_period_id;
  if not found then
    return jsonb_build_object('ok',false,'error','no_period','tone','danger',
      'message', public._pop_c('ack.err_no_period'));
  end if;
  if v_partner is null or p.partner_id is distinct from v_partner
     or not public.partner_can('partner.settlement','read') then
    return jsonb_build_object('ok',false,'error','not_authorized','tone','danger',
      'message', public._pop_c('ack.err_not_authorized'));
  end if;

  insert into partner_settlement_ack(period_id, partner_id, state, note, by_identity, by_partner_user)
  values (p_period_id, v_partner, p_state, nullif(btrim(coalesce(p_note,'')),''),
          coalesce(public.my_login_email(),'partner'), public.my_partner_user_id())
  on conflict (period_id) do update
    set state = excluded.state, note = excluded.note, by_identity = excluded.by_identity,
        by_partner_user = excluded.by_partner_user, acked_at = now(),
        resolved_at = null, resolved_by = null, resolve_note = null;

  perform public.partner_audit('partner.settlement','settlement_' || p_state,
    jsonb_build_object('period_id',p_period_id,'note',p_note,
                       'summary', initcap(p_state) || ' settlement period ' || p_period_id));

  -- Only AUTOMATIC mode actually holds money, so only it may say so.
  select coalesce(route_mode,'manual') into v_mode from settlement_config where id = 1;
  v_msg := case when p_state = 'agreed' then public._pop_c('ack.agreed_toast')
                when coalesce(v_mode,'manual') = 'automatic' then public._pop_c('ack.disputed_toast')
                else public._pop_c('ack.disputed_toast_manual') end;

  return jsonb_build_object('ok',true,'tone', case when p_state='agreed' then 'success' else 'warning' end,
    'message', v_msg, 'ack', public._stl_ack_block(p_period_id, false));
end $function$
;

CREATE OR REPLACE FUNCTION public.settlement_settle(p_period_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_mode text; v_frozen boolean;
begin
  if not public.is_admin() then return public._stl_denied(); end if;
  if not exists (select 1 from public.partner_settlement_periods where id = p_period_id) then
    return jsonb_build_object('ok', false, 'message', public._stl_c('err.no_period'));
  end if;

  select coalesce(route_mode,'manual') into v_mode from public.settlement_config where id = 1;
  select (state = 'disputed' and resolved_at is null) into v_frozen
    from public.partner_settlement_ack where period_id = p_period_id;

  if coalesce(v_frozen,false) and coalesce(v_mode,'manual') = 'automatic' then
    return jsonb_build_object('ok', false, 'error','disputed_frozen','tone','danger',
      'message', public._pop_c('ack.err_frozen_settle'),
      'statement', public.settlement_statement(p_period_id));
  end if;

  update public.partner_settlement_periods
     set status = 'settled', settled_at = now(),
         settled_by = coalesce(auth.jwt() ->> 'email','admin')
   where id = p_period_id;
  return jsonb_build_object('ok', true, 'message', public._stl_c('period.settled_msg'),
                            'statement', public.settlement_statement(p_period_id));
end $function$
;

CREATE OR REPLACE FUNCTION public.settlement_statement(p_period_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  p public.partner_settlement_periods%rowtype;
  cfg public.settlement_config%rowtype;
  v_paid numeric; v_pending numeric;
  v_admin boolean := public.is_admin();
  v_ack jsonb; v_frozen boolean;
begin
  select * into p from public.partner_settlement_periods where id = p_period_id;
  if not found then
    return jsonb_build_object('ok', false, 'message', public._stl_c('err.no_period'));
  end if;
  if not v_admin and p.partner_id is distinct from public.my_partner_id() then
    return jsonb_build_object('ok', false, 'message', public._stl_c('ui.partner_denied'));
  end if;
  select * into cfg from public.settlement_config where id = 1;

  select coalesce(sum(amount) filter (where status = 'paid'), 0)
    into v_paid from public.partner_settlement_payments where period_id = p.id;
  v_pending := round(greatest(p.payable - v_paid, 0), 2);

  v_ack := public._stl_ack_block(p.id, v_admin);
  v_frozen := coalesce((v_ack->>'frozen')::boolean, false)
              and coalesce(cfg.route_mode,'manual') = 'automatic';

  return jsonb_build_object(
    'ok', true,
    'period_id', p.id,
    'title',    public._stl_c('ui.title'),
    'heading',  format(public._stl_c('period.window'),
                       public.ist_fmt(p.period_start::timestamptz, 'dmy'),
                       public.ist_fmt(p.period_end::timestamptz, 'dmy')),
    'sub',      public._stl_c('cad.' || p.cadence) || ' · ' ||
                format(public._stl_c('period.due_on'),
                       public.ist_fmt(p.due_on::timestamptz, 'dmy')),
    'partner',  coalesce((select partner_name from public.region_partners where id = p.partner_id), ''),
    'status',       p.status,
    'status_label', public._stl_c('period.' || p.status),
    'status_tone',  public._stl_tone('period.' || p.status),
    'is_admin',     v_admin,
    'ack',          v_ack,
    'payout_frozen', v_frozen,
    'can_settle',   v_admin and p.status = 'due' and not v_frozen,
    'settle_label', public._stl_c('period.settle'),
    'record_label', public._stl_c('route.record'),
    'amount_label', public._stl_c('fld.amount'),
    'reference_label', public._stl_c('fld.reference'),
    'route_mode',   coalesce(cfg.route_mode,'manual'),
    'route_label',  public._stl_c('route.' || coalesce(cfg.route_mode,'manual')),
    'route_note',   public._stl_c('route.' || coalesce(cfg.route_mode,'manual') || '_note'),
    'negative',     p.payable = 0 and p.net_due < 0,
    'negative_text',public._stl_c('period.negative'),
    'tiles', jsonb_build_array(
      public._stl_money_tile('tile.revenue',       p.revenue),
      public._stl_money_tile('tile.goods',         p.goods_cost),
      public._stl_money_tile('tile.gross',         p.gross_margin),
      public._stl_money_tile('tile.costs',         p.cost_total),
      public._stl_money_tile('tile.distributable', p.distributable),
      public._stl_money_tile('tile.medibo',        p.medibo_share),
      public._stl_money_tile('tile.partner',       p.partner_share),
      public._stl_money_tile('tile.brought_forward', p.brought_forward),
      public._stl_money_tile('tile.due',           p.payable),
      public._stl_money_tile('tile.transferred',   v_paid),
      public._stl_money_tile('tile.pending',       v_pending),
      public._stl_money_tile('tile.carry_forward', p.carry_forward),
      public._stl_tile('tile.orders', p.orders_count::text)),
    -- CHANGE #400 fix: min()/sum() must be aggregated in an inner query before
    -- jsonb_agg wraps them. As written in #323 this raised "aggregate function
    -- calls cannot be nested" on EVERY call — invisible only because no
    -- settlement period existed yet.
    'costs', jsonb_build_object(
      'heading', public._stl_c('sec.cost_lines'),
      'rows', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'label', g.label,
                 'sub',   public._stl_c('basis.' || g.basis),
                 'value', public.inr_money(g.amt))
               order by g.sort_order)
          from (select ct.label, ct.sort_order,
                       coalesce(min(oc.basis), ct.basis) as basis,
                       sum(coalesce(oc.override_amount, oc.computed_amount)) as amt
                  from public.order_costs oc
                  join public.cost_types ct on ct.slug = oc.cost_type
                 where oc.order_id in (select order_id from public.partner_settlements
                                        where period_id = p.id)
                 group by ct.slug, ct.label, ct.sort_order, ct.basis) g), '[]'::jsonb)),
    'orders', jsonb_build_object(
      'heading', public._stl_c('sec.orders'),
      'empty_text', public._stl_c('ui.empty'),
      'rows', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'order_id', s.order_id,
                 'label', coalesce(s.order_code, ''),
                 'sub', public.ist_fmt(s.order_date::timestamptz, 'dmy') || ' · ' ||
                        public._stl_c('tile.gross') || ' ' || public.inr_money(s.gross_margin) ||
                        ' · ' || public._stl_c('tile.costs') || ' ' || public.inr_money(s.cost_total),
                 'value', public.inr_money(s.distributable),
                 'value_tone', case when s.distributable < 0 then 'danger' end)
               order by s.order_date, s.order_code)
          from public.partner_settlements s where s.period_id = p.id), '[]'::jsonb)),
    'payments', jsonb_build_object(
      'heading', public._stl_c('sec.payments'),
      'empty_text', public._stl_c('period.empty'),
      'rows', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'label', public._stl_c('route.' || case when x.method = 'razorpay_route'
                                                         then 'automatic' else 'manual' end),
                 'sub', case when x.status = 'queued' then public._stl_c('route.queued')
                             else coalesce(nullif(x.rzp_transfer_id,''), nullif(x.reference,''), '') end ||
                        ' · ' || public.ist_fmt(x.paid_at, 'dmy'),
                 'value', public.inr_money(x.amount),
                 'value_tone', case when x.status = 'queued' then 'warning' else 'success' end)
               order by x.paid_at desc)
          from public.partner_settlement_payments x where x.period_id = p.id), '[]'::jsonb)),
    'footnote', public._stl_c('ui.footnote'));
end $function$
;


-- ── 7. grants: nothing new is anon-callable (the #401 lesson, applied up front) ──
revoke execute on function public._pop_c(text) from public, anon;
revoke execute on function public._pob_step_done(bigint,text) from public, anon;
revoke execute on function public._stl_ack_block(bigint,boolean) from public, anon;
revoke execute on function public.partner_workers_console() from public, anon;
revoke execute on function public.partner_worker_add(text,text,text) from public, anon;
revoke execute on function public.partner_worker_remove(bigint) from public, anon;
revoke execute on function public.partner_worker_shift_set(bigint,text,date) from public, anon;
revoke execute on function public.settlement_ack_set(bigint,text,text) from public, anon;
revoke execute on function public.settlement_ack_resolve(bigint,text) from public, anon;
revoke execute on function public.partner_onboarding_get(bigint) from public, anon;
revoke execute on function public.partner_onboarding_set(bigint,text,text,text) from public, anon;
revoke execute on function public.partner_set_active(bigint,boolean,text) from public, anon;

grant execute on function public._pop_c(text) to authenticated, service_role;
grant execute on function public._pob_step_done(bigint,text) to authenticated, service_role;
grant execute on function public._stl_ack_block(bigint,boolean) to authenticated, service_role;
grant execute on function public.partner_workers_console() to authenticated;
grant execute on function public.partner_worker_add(text,text,text) to authenticated;
grant execute on function public.partner_worker_remove(bigint) to authenticated;
grant execute on function public.partner_worker_shift_set(bigint,text,date) to authenticated;
grant execute on function public.settlement_ack_set(bigint,text,text) to authenticated;
grant execute on function public.settlement_ack_resolve(bigint,text) to authenticated;
grant execute on function public.partner_onboarding_get(bigint) to authenticated;
grant execute on function public.partner_onboarding_set(bigint,text,text,text) to authenticated;
grant execute on function public.partner_set_active(bigint,boolean,text) to authenticated;
