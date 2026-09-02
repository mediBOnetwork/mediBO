-- CMD #467 — the three remaining APPROVED severity=low feature_gaps rows.
--
--   row 52  (supplier) supplier_set_packed returns a bare error slug with no copy
--   row 113 (delivery) delivery_partner_registrations carries duplicated RLS pairs
--   row 155 (partner)  partner actions are audited but the log is unreadable
--
-- Everything here is idempotent: a resumed worker re-runs the whole file and
-- every statement is a no-op the second time.

-- ═══════════════════════════════════════════════════════════════════════════
-- ROW 52 — every supplier error slug carries backend copy
-- ═══════════════════════════════════════════════════════════════════════════
-- The supplier surface had 18 two-argument `jsonb_build_object('error','slug')`
-- returns across 11 RPCs. They carried no `ok` and no `message`, so the Flutter
-- side had to invent the wording — and supplier_set_packed's caller invented
-- nothing at all: it awaited the RPC, saw no thrown exception, and called
-- onReload() as if the pack had happened. A supplier tapping Pack on someone
-- else's order got silence.
--
-- One helper composes the refusal; ui_copy holds the words. Adding a new slug
-- is now an INSERT, never a deploy.

create or replace function public.supplier_err(p_slug text, p_extra jsonb default '{}'::jsonb)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select jsonb_build_object(
           'ok', false,
           'error', p_slug,
           'message', public.uic('supplier_err.' || p_slug,
                                 public.uic('supplier_err.default',
                                            'That could not be completed. Refresh and try again.')))
         || coalesce(p_extra, '{}'::jsonb);
$$;

comment on function public.supplier_err(text, jsonb) is
  'CMD #467 row 52 — one refusal shape for the supplier surface: ok:false + the slug + the copy from ui_copy (supplier_err.<slug>). Never returns a bare slug.';

insert into public.ui_copy(key, value) values
  ('supplier_err.default',            '"That could not be completed. Refresh and try again."'::jsonb),
  ('supplier_err.not_found',          '"That order is no longer on the list. Refresh to see the current one."'::jsonb),
  ('supplier_err.not_authorized',     '"This order belongs to another supplier, so it cannot be changed here."'::jsonb),
  ('supplier_err.not_supplier',       '"This login is not linked to a supplier account yet."'::jsonb),
  ('supplier_err.no_supplier',        '"This login is not linked to a supplier account yet."'::jsonb),
  ('supplier_err.not_current',        '"This enquiry has already moved on to another supplier."'::jsonb),
  ('supplier_err.not_in_inquiry',     '"This item is not part of the enquiry you were asked about."'::jsonb),
  ('supplier_err.already_answered',   '"You have already answered this item. Your earlier answer is shown."'::jsonb),
  ('supplier_err.invalid_answer',     '"Pick one of the answers shown before sending."'::jsonb),
  ('supplier_err.invalid',            '"That request could not be read. Refresh and try again."'::jsonb),
  ('supplier_err.not_your_dispute',   '"This dispute belongs to another supplier."'::jsonb)
on conflict (key) do nothing;

-- Rewrite the bare returns in place. pg_get_functiondef() output is exactly
-- re-executable, so each function is re-created from its own live definition
-- with only the refusal expression swapped. Re-running finds no bare pattern
-- left and rewrites nothing.
do $rewrite$
declare
  r record;
  v_new text;
begin
  for r in
    select p.oid, p.proname, pg_get_functiondef(p.oid) as def
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and (p.proname like 'supplier\_%' or p.proname like 'sup\_%')
      and pg_get_functiondef(p.oid) ~ 'jsonb_build_object\(\s*''error''\s*,\s*''[a-z_]+''\s*[,)]'
  loop
    v_new := r.def;

    -- the one branch that carries an extra key travels through p_extra
    v_new := regexp_replace(
      v_new,
      'jsonb_build_object\(\s*''error''\s*,\s*''already_answered''\s*,\s*''answer''\s*,\s*([a-zA-Z0-9_.]+)\s*\)',
      'public.supplier_err(''already_answered'', jsonb_build_object(''answer'', \1))',
      'g');

    -- every plain two-argument refusal
    v_new := regexp_replace(
      v_new,
      'jsonb_build_object\(\s*''error''\s*,\s*''([a-z_]+)''\s*\)',
      'public.supplier_err(''\1'')',
      'g');

    if v_new is distinct from r.def then
      execute v_new;
      raise notice 'c467: rewrote %', r.proname;
    end if;
  end loop;
end
$rewrite$;

-- ═══════════════════════════════════════════════════════════════════════════
-- ROW 113 — one RLS policy per command on delivery_partner_registrations
-- ═══════════════════════════════════════════════════════════════════════════
-- CHANGE #307 created each policy twice, under its old title-case name and
-- again under a snake_case name, so six policies were evaluated on every read.
-- Permissive policies OR together, so the effective predicate is unchanged by
-- dropping the older three:
--
--   ALL     "Admin full dp_reg"     == admin_all        (identical expressions)
--   INSERT  "User insert own dp_reg" == user_insert_own (identical expressions)
--   SELECT  "User select own dp_reg" (uid = user_id)
--           user_select_own          (uid = user_id OR is_admin())
--           OR of the two            = uid = user_id OR is_admin()
--                                    = user_select_own alone
--
-- Nobody loses a row they could read before; the ambiguity about which SELECT
-- policy is authoritative goes away because only one is left.
drop policy if exists "Admin full dp_reg"      on public.delivery_partner_registrations;
drop policy if exists "User insert own dp_reg" on public.delivery_partner_registrations;
drop policy if exists "User select own dp_reg" on public.delivery_partner_registrations;

-- The three survivors, asserted rather than assumed: if a future migration
-- drops the snake_case name instead, this file recreates it at its known shape.
do $dp$
begin
  if not exists (select 1 from pg_policies
                  where schemaname='public' and tablename='delivery_partner_registrations'
                    and policyname='admin_all') then
    execute $p$create policy admin_all on public.delivery_partner_registrations
              for all to authenticated
              using      (is_admin() and public.partner_zone_ok(zone_id))
              with check (is_admin() and public.partner_zone_ok(zone_id))$p$;
  end if;
  if not exists (select 1 from pg_policies
                  where schemaname='public' and tablename='delivery_partner_registrations'
                    and policyname='user_insert_own') then
    execute $p$create policy user_insert_own on public.delivery_partner_registrations
              for insert to authenticated
              with check (auth.uid() = user_id)$p$;
  end if;
  if not exists (select 1 from pg_policies
                  where schemaname='public' and tablename='delivery_partner_registrations'
                    and policyname='user_select_own') then
    execute $p$create policy user_select_own on public.delivery_partner_registrations
              for select to authenticated
              using (auth.uid() = user_id or is_admin())$p$;
  end if;
end
$dp$;

-- ═══════════════════════════════════════════════════════════════════════════
-- ROW 155 — the partner audit log becomes readable
-- ═══════════════════════════════════════════════════════════════════════════
-- partner_audit() has always written a good record. The only reader was
-- admin_partner_console(), which returned the last 25 rows for one partner
-- with no filter, no paging and no date range — so an `open_denied`, the one
-- entry that says a partner is probing a feature it was never granted, fell
-- off the bottom of the list within a day and could never be searched for.
--
-- admin_partner_audit_list() is that reader: filter by feature, by action and
-- by date, page with offset, and every word on the screen — the headings, the
-- filter options, each row's one line, the counts, the empty state and the
-- denied banner — is composed here. The screen renders and does not decide.

insert into public.ui_copy(key, value) values
  ('partner_audit.title',          '"Partner activity"'::jsonb),
  ('partner_audit.subtitle',       '"Every open, refusal and permission change recorded for this partner."'::jsonb),
  ('partner_audit.open_label',     '"View full activity"'::jsonb),
  ('partner_audit.empty',          '"No activity matches these filters."'::jsonb),
  ('partner_audit.more_label',     '"Load older activity"'::jsonb),
  ('partner_audit.filter_feature', '"Feature"'::jsonb),
  ('partner_audit.filter_action',  '"What happened"'::jsonb),
  ('partner_audit.filter_range',   '"Period"'::jsonb),
  ('partner_audit.any_feature',    '"All features"'::jsonb),
  ('partner_audit.any_action',     '"Everything"'::jsonb),
  ('partner_audit.denied_banner',  '"{n} refused attempts in this period — a partner opening features it was not granted."'::jsonb),
  ('partner_audit.denied_none',    '"No refused attempts in this period."'::jsonb),
  ('partner_audit.count_one',      '"1 entry"'::jsonb),
  ('partner_audit.count_many',     '"{n} entries"'::jsonb),
  ('partner_audit.not_authorized', '"Only a mediBO admin can read partner activity."'::jsonb),
  ('partner_audit.partner_not_found', '"That partner record no longer exists."'::jsonb),
  ('partner_audit.range_7',        '"Last 7 days"'::jsonb),
  ('partner_audit.range_30',       '"Last 30 days"'::jsonb),
  ('partner_audit.range_90',       '"Last 90 days"'::jsonb),
  ('partner_audit.range_all',      '"All time"'::jsonb),
  ('partner_audit.no_feature',     '"No feature"'::jsonb),
  ('partner_audit.load_failed',    '"Could not reach the server. Nothing is shown because nothing was read."'::jsonb),
  ('partner_audit.retry',          '"Try again"'::jsonb)
on conflict (key) do nothing;

-- The verbatim sentence for one row, and the tone that colours it. A new
-- action type gets a row here, not a Dart branch.
create table if not exists public.partner_audit_action_copy (
  action     text primary key,
  label      text not null,
  line       text not null,      -- {feature} is substituted, nothing else
  tone       text not null default 'neutral',
  sort_order int  not null default 100
);

insert into public.partner_audit_action_copy(action, label, line, tone, sort_order) values
  ('open',                   'Opened',            'Opened {feature}',                        'neutral', 10),
  ('open_denied',            'Refused',           'Refused: tried to open {feature}',        'danger',  20),
  ('permission_set',         'Access changed',    'Access changed on {feature}',             'info',    30),
  ('login_added',            'Login added',       'A staff login was added',                 'success', 40),
  ('login_removed',          'Login removed',     'A staff login was removed',               'warning', 50),
  ('partner_suspended',      'Suspended',         'Partner suspended',                       'danger',  60),
  ('partner_resumed',        'Resumed',           'Partner resumed',                         'success', 70),
  ('licence_expiry_set',     'Licence updated',   'Licence expiry updated',                  'info',    80),
  ('licence_expiry_reminder','Licence reminder',  'Licence expiry reminder sent',            'warning', 90)
on conflict (action) do nothing;

alter table public.partner_audit_action_copy enable row level security;
do $rls$
begin
  if not exists (select 1 from pg_policies
                  where schemaname='public' and tablename='partner_audit_action_copy'
                    and policyname='read_all_audit_copy') then
    execute $p$create policy read_all_audit_copy on public.partner_audit_action_copy
              for select to authenticated using (true)$p$;
  end if;
end
$rls$;

-- The feature filter needs a label per feature_key; feature_registry has it.
create or replace function public.admin_partner_audit_list(
  p_partner_id bigint,
  p_feature    text    default null,
  p_action     text    default null,
  p_days       int     default 30,
  p_limit      int     default 25,
  p_offset     int     default 0
) returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_lim    int := least(greatest(coalesce(p_limit, 25), 1), 100);
  v_off    int := greatest(coalesce(p_offset, 0), 0);
  v_days   int := case when coalesce(p_days, 30) <= 0 then null else p_days end;
  v_from   timestamptz := case when v_days is null then null else now() - make_interval(days => v_days) end;
  v_feat   text := nullif(btrim(coalesce(p_feature, '')), '');
  v_act    text := nullif(btrim(coalesce(p_action, '')), '');
  rp       record;
  v_rows   jsonb;
  v_total  bigint;
  v_denied bigint;
  v_feats  jsonb;
  v_acts   jsonb;
  v_ranges jsonb;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'message', public.uic('partner_audit.not_authorized',''));
  end if;

  select * into rp from region_partners where id = p_partner_id;
  if rp.id is null then
    return jsonb_build_object('ok', false, 'error', 'partner_not_found',
      'message', public.uic('partner_audit.partner_not_found',''));
  end if;

  -- The filtered set, counted once. partner_audit_log is indexed on
  -- (partner_id, created_at desc), so the predicate is simply repeated for the
  -- count and the page rather than materialised — a STABLE function may not
  -- create a temp table, and this one must stay STABLE.
  select count(*), count(*) filter (where al.action = 'open_denied')
    into v_total, v_denied
  from partner_audit_log al
  where al.partner_id = p_partner_id
    and (v_from is null or al.created_at >= v_from)
    and (v_feat  is null or coalesce(al.feature_key,'') = v_feat)
    and (v_act   is null or al.action = v_act);

  select jsonb_agg(x order by x_created desc) into v_rows
  from (
    select jsonb_build_object(
             'id', a.id,
             'action', a.action,
             'feature_key', coalesce(a.feature_key,''),
             'action_label', coalesce(ac.label, a.action),
             'line', replace(coalesce(ac.line, a.action),
                             '{feature}',
                             coalesce(nullif(fr.label,''),
                                      nullif(a.feature_key,''),
                                      public.uic('partner_audit.no_feature','No feature'))),
             'tone', coalesce(ac.tone, 'neutral'),
             'at_label', to_char(a.created_at at time zone 'Asia/Kolkata', 'dd Mon yyyy, HH24:MI'),
             'who', coalesce(a.user_id::text, ''),
             'zone_id', a.zone_id) as x,
           a.created_at as x_created
    from partner_audit_log a
    left join partner_audit_action_copy ac on ac.action = a.action
    left join feature_registry fr on fr.feature_key = a.feature_key
    where a.partner_id = p_partner_id
      and (v_from is null or a.created_at >= v_from)
      and (v_feat  is null or coalesce(a.feature_key,'') = v_feat)
      and (v_act   is null or a.action = v_act)
    order by a.created_at desc
    limit v_lim offset v_off
  ) s;

  -- the feature filter offers exactly the features this partner has touched
  select jsonb_agg(jsonb_build_object(
           'value', f.feature_key,
           'label', coalesce(nullif(fr.label,''), nullif(f.feature_key,''),
                             public.uic('partner_audit.no_feature','No feature')),
           'count', f.n,
           'selected', v_feat is not distinct from f.feature_key)
         order by f.n desc, f.feature_key)
    into v_feats
  from (select coalesce(feature_key,'') feature_key, count(*) n
        from partner_audit_log
        where partner_id = p_partner_id
          and (v_from is null or created_at >= v_from)
        group by 1) f
  left join feature_registry fr on fr.feature_key = f.feature_key;

  select jsonb_agg(jsonb_build_object(
           'value', a.action,
           'label', coalesce(ac.label, a.action),
           'count', a.n,
           'tone', coalesce(ac.tone,'neutral'),
           'selected', v_act is not distinct from a.action)
         order by coalesce(ac.sort_order, 100), a.action)
    into v_acts
  from (select action, count(*) n
        from partner_audit_log
        where partner_id = p_partner_id
          and (v_from is null or created_at >= v_from)
        group by 1) a
  left join partner_audit_action_copy ac on ac.action = a.action;

  v_ranges := jsonb_build_array(
    jsonb_build_object('value', 7,  'label', public.uic('partner_audit.range_7','Last 7 days'),   'selected', coalesce(p_days,30) = 7),
    jsonb_build_object('value', 30, 'label', public.uic('partner_audit.range_30','Last 30 days'), 'selected', coalesce(p_days,30) = 30),
    jsonb_build_object('value', 90, 'label', public.uic('partner_audit.range_90','Last 90 days'), 'selected', coalesce(p_days,30) = 90),
    jsonb_build_object('value', 0,  'label', public.uic('partner_audit.range_all','All time'),    'selected', coalesce(p_days,30) <= 0));

  return jsonb_build_object(
    'ok', true,
    'partner_id', rp.id,
    'partner_name', coalesce(rp.partner_name,''),
    'title',    public.uic('partner_audit.title','Partner activity'),
    'subtitle', public.uic('partner_audit.subtitle',''),
    'empty',    public.uic('partner_audit.empty',''),
    'more_label', public.uic('partner_audit.more_label','Load older activity'),
    'filter_feature_label', public.uic('partner_audit.filter_feature','Feature'),
    'filter_action_label',  public.uic('partner_audit.filter_action','What happened'),
    'filter_range_label',   public.uic('partner_audit.filter_range','Period'),
    'any_feature_label',    public.uic('partner_audit.any_feature','All features'),
    'any_action_label',     public.uic('partner_audit.any_action','Everything'),
    'count_label', case when v_total = 1
                        then public.uic('partner_audit.count_one','1 entry')
                        else replace(public.uic('partner_audit.count_many','{n} entries'),
                                     '{n}', v_total::text) end,
    'denied_count', v_denied,
    'denied_tone', case when v_denied > 0 then 'danger' else 'neutral' end,
    'denied_label', case when v_denied > 0
                         then replace(public.uic('partner_audit.denied_banner',''), '{n}', v_denied::text)
                         else public.uic('partner_audit.denied_none','') end,
    'total', v_total,
    'limit', v_lim,
    'offset', v_off,
    'next_offset', v_off + v_lim,
    'has_more', (v_off + v_lim) < v_total,
    'days', coalesce(p_days, 30),
    'feature', coalesce(v_feat, ''),
    'action', coalesce(v_act, ''),
    'ranges', v_ranges,
    'features', coalesce(v_feats, '[]'::jsonb),
    'actions',  coalesce(v_acts,  '[]'::jsonb),
    'rows',     coalesce(v_rows,  '[]'::jsonb));
end
$$;

comment on function public.admin_partner_audit_list(bigint, text, text, int, int, int) is
  'CMD #467 row 155 — the readable partner audit trail: filter by feature/action/period, page by offset, every string composed here.';

-- Every SECURITY DEFINER function inherits Postgres's default GRANT TO PUBLIC,
-- and the anon key ships inside the web bundle and the APK. An admin reader of
-- the audit trail must never be a public endpoint (rg_check behaviour
-- `privileged_rpcs_are_not_anon` catches exactly this).
revoke execute on function public.admin_partner_audit_list(bigint, text, text, int, int, int) from public, anon;
revoke execute on function public.supplier_err(text, jsonb) from public, anon;
grant execute on function public.admin_partner_audit_list(bigint, text, text, int, int, int) to authenticated;
grant execute on function public.supplier_err(text, jsonb) to authenticated;

-- The console keeps its 25-row preview but now carries the door to the full
-- log, plus the same one-line-per-row shape the full screen uses, so the two
-- surfaces never word an entry differently.
create or replace function public.admin_partner_audit_preview(p_partner_id bigint, p_limit int default 25)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', a.id,
           'action', a.action,
           'feature_key', coalesce(a.feature_key,''),
           'action_label', coalesce(ac.label, a.action),
           'line', replace(coalesce(ac.line, a.action), '{feature}',
                           coalesce(nullif(fr.label,''), nullif(a.feature_key,''),
                                    public.uic('partner_audit.no_feature','No feature'))),
           'tone', coalesce(ac.tone,'neutral'),
           'at_label', to_char(a.created_at at time zone 'Asia/Kolkata','dd Mon, HH24:MI'))
         order by a.created_at desc), '[]'::jsonb)
  from (select * from partner_audit_log
         where partner_id = p_partner_id
         order by created_at desc
         limit greatest(coalesce(p_limit,25),1)) a
  left join partner_audit_action_copy ac on ac.action = a.action
  left join feature_registry fr on fr.feature_key = a.feature_key;
$$;

revoke execute on function public.admin_partner_audit_preview(bigint, int) from public, anon;
grant execute on function public.admin_partner_audit_preview(bigint, int) to authenticated;

-- The console's Activity card now prints the same composed line as the full
-- screen, and carries the button that opens it. `audit_open` is a descriptor,
-- not a flag: no label in the payload means no button on the screen.
create or replace function public.admin_partner_console(p_partner_id bigint)
 returns jsonb
 language plpgsql
 stable
 security definer
 set search_path to 'public'
as $function$
declare
  v_copy jsonb := coalesce((select value from app_settings where key='partner_admin_copy'),'{}'::jsonb);
  rp record; v_feats jsonb; v_users jsonb; v_audit jsonb;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized',
      'message', coalesce(v_copy->>'err_not_authorized',''));
  end if;
  select * into rp from region_partners where id = p_partner_id;
  if rp.id is null then
    return jsonb_build_object('ok',false,'error','partner_not_found',
      'message', coalesce(v_copy->>'err_partner_not_found',''));
  end if;

  select jsonb_agg(jsonb_build_object(
           'feature_key', fr.feature_key,
           'label', fr.label,
           'group_label', fr.group_label,
           'access', coalesce(pp.access,'none'),
           'options', jsonb_build_array(
             jsonb_build_object('value','none', 'label','No access',
                                'selected', coalesce(pp.access,'none')='none'),
             jsonb_build_object('value','read', 'label','View only',
                                'selected', coalesce(pp.access,'none')='read'),
             jsonb_build_object('value','write','label','Full access',
                                'selected', coalesce(pp.access,'none')='write')))
         order by fr.sort_order)
    into v_feats
  from feature_registry fr
  left join partner_permissions pp
         on pp.feature_key = fr.feature_key and pp.partner_id = p_partner_id
  where fr.is_active and fr.owner = 'partner' and fr.partner_eligible;

  select jsonb_agg(jsonb_build_object(
           'id', pu.id, 'identity', pu.identity,
           'display_name', coalesce(pu.display_name,''),
           'is_active', pu.is_active,
           'linked', (pu.auth_user_id is not null),
           'status_label', case when pu.auth_user_id is not null then 'Signed in'
                                else 'Waiting for first login' end,
           'added_label', to_char(pu.created_at at time zone 'Asia/Kolkata','dd Mon yyyy'))
         order by pu.id)
    into v_users
  from partner_users pu where pu.partner_id = p_partner_id and pu.is_active;

  -- CMD #467 row 155 — one composer for both surfaces.
  v_audit := public.admin_partner_audit_preview(p_partner_id, 25);

  return jsonb_build_object(
    'ok', true,
    'partner_id', rp.id,
    'partner_name', coalesce(rp.partner_name,''),
    'district', coalesce(rp.district,''),
    'zone_id', rp.zone_id,
    'zone_label', coalesce((select name from zones where id = rp.zone_id),''),
    'zone_locked_label', coalesce(v_copy->>'zone_locked_label',''),
    'users_title', coalesce(v_copy->>'users_title',''),
    'users_subtitle', coalesce(v_copy->>'users_subtitle',''),
    'add_label', coalesce(v_copy->>'add_label',''),
    'add_hint', coalesce(v_copy->>'add_hint',''),
    'name_hint', coalesce(v_copy->>'name_hint',''),
    'remove_label', coalesce(v_copy->>'remove_label',''),
    'empty_users', coalesce(v_copy->>'empty_users',''),
    'perm_title', coalesce(v_copy->>'perm_title',''),
    'perm_subtitle', coalesce(v_copy->>'perm_subtitle',''),
    'audit_title', coalesce(v_copy->>'audit_title',''),
    'empty_audit', coalesce(v_copy->>'empty_audit',''),
    -- CMD #467 row 155 — the door to the filterable, paged log. A build that
    -- has never heard of the screen simply renders no button.
    'audit_open', jsonb_build_object(
      'label', public.uic('partner_audit.open_label','View full activity'),
      'partner_id', rp.id),
    -- CHANGE #321: what the screen says when the RPC itself never answers.
    'failed_message', coalesce(v_copy->>'failed_message',''),
    -- CHANGE #352 — the Partner fence card: what this login can actually reach
    -- over the raw API. Composed entirely by partner_fence_card().
    'fence', public.partner_fence_card(),
    -- CMD #466 rows 153 + 154 — status/suspension and licence expiry.
    'lifecycle', public.partner_lifecycle_card(rp.id),
    'licences', public.partner_licence_card(rp.id),
    'users', coalesce(v_users,'[]'::jsonb),
    'features', coalesce(v_feats,'[]'::jsonb),
    'audit', coalesce(v_audit,'[]'::jsonb));
end $function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- QA round — the blocker this command found on itself, retired as a class
-- ═══════════════════════════════════════════════════════════════════════════
-- rg_check's `privileged_rpcs_are_not_anon` caught admin_partner_audit_list
-- EXECUTE-able by anon: every SECURITY DEFINER function inherits Postgres's
-- default GRANT TO PUBLIC and the anon key ships inside the web bundle and the
-- APK. Writing the journey for it surfaced a second, quieter hole in the same
-- class: admin_partner_audit_preview() was SECURITY DEFINER, granted to
-- `authenticated`, and had NO guard in its body — so any logged-in pharmacy or
-- rider could have read any partner's audit trail by calling it directly. A
-- grant is not a guard; the body has to say no as well.
create or replace function public.admin_partner_audit_preview(p_partner_id bigint, p_limit int default 25)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare v_rows jsonb;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return '[]'::jsonb;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', a.id,
           'action', a.action,
           'feature_key', coalesce(a.feature_key,''),
           'action_label', coalesce(ac.label, a.action),
           'line', replace(coalesce(ac.line, a.action), '{feature}',
                           coalesce(nullif(fr.label,''), nullif(a.feature_key,''),
                                    public.uic('partner_audit.no_feature','No feature'))),
           'tone', coalesce(ac.tone,'neutral'),
           'at_label', to_char(a.created_at at time zone 'Asia/Kolkata','dd Mon, HH24:MI'))
         order by a.created_at desc), '[]'::jsonb)
    into v_rows
  from (select * from partner_audit_log
         where partner_id = p_partner_id
         order by created_at desc
         limit greatest(coalesce(p_limit,25),1)) a
  left join partner_audit_action_copy ac on ac.action = a.action
  left join feature_registry fr on fr.feature_key = a.feature_key;

  return v_rows;
end $$;

revoke execute on function public.admin_partner_audit_preview(bigint, int) from public, anon;
grant  execute on function public.admin_partner_audit_preview(bigint, int) to authenticated;

-- Writing the journey found two more members of the same class, both older than
-- this command and both fixed here rather than reported:
--   * partner_licence_expiry_sweep() — a cron job, SECURITY DEFINER, with no
--     caller check and EXECUTE for anon. Anyone holding the key that ships in
--     the bundle could have fired the reminder sweep at will. It runs from the
--     cron dispatcher as its owner, so revoking every client role costs it
--     nothing.
--   * partner_staff_console() turned out to be fine — it scopes itself with
--     my_partner_id() + partner_access(), which the first draft of the
--     assertion below did not recognise. The lesson is in the regex: a guard
--     is any check that ties the read to the CALLER, not one function name.
revoke execute on function public.partner_licence_expiry_sweep() from public, anon, authenticated;

-- The journey. It asserts the CLASS, not the one revoke: the three doors still
-- exist (a bool_and over a vanished function is silently true), none of them is
-- reachable with the key that ships in the bundle, the app is not locked out,
-- every client-reachable reader of partner_audit_log ties its read to the
-- caller, the log table is selectable by neither client role, and the cron-only
-- sweep is reachable by neither.
create or replace function public._journey_c467_partner_audit_fence()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_present int; v_anon int; v_noauth int; v_unguarded int;
  v_a1 boolean; v_a2 boolean; v_a3 boolean; v_a4 boolean; v_a5 boolean; v_a6 boolean;
  v_ok boolean;
  c_fns constant text[] := array['admin_partner_audit_list',
                                 'admin_partner_audit_preview',
                                 'admin_partner_console'];
  -- a guard is anything that ties the read to the CALLER, not one function name
  c_guard constant text :=
    '(role_for_medibo_only|get_my_role|is_admin|_dev_guard|my_partner_id|partner_access|is_partner|auth\.uid)';
begin
  select count(*) into v_present
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = any (c_fns);
  v_a1 := v_present >= 3;

  select count(*) into v_anon
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = any (c_fns)
     and has_function_privilege('anon', p.oid, 'execute');
  v_a2 := v_anon = 0;

  select count(*) into v_noauth
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = any (c_fns)
     and not has_function_privilege('authenticated', p.oid, 'execute');
  v_a3 := v_noauth = 0;

  -- a grant is not a guard: every CLIENT-REACHABLE reader of partner_audit_log
  -- must refuse a caller it cannot place, whatever EXECUTE says. The writer and
  -- the internal cNNN_*_proof helpers are not client doors and are excluded.
  select count(*) into v_unguarded
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.prosecdef
     and p.prosrc like '%partner_audit_log%'
     and p.proname <> 'partner_audit'
     and p.proname !~ '^c[0-9]+_'
     and p.proname !~ '^_journey'
     and (has_function_privilege('anon', p.oid, 'execute')
          or has_function_privilege('authenticated', p.oid, 'execute'))
     and p.prosrc !~ c_guard;
  v_a4 := v_unguarded = 0;

  v_a5 := not has_table_privilege('anon','public.partner_audit_log','select')
      and not has_table_privilege('authenticated','public.partner_audit_log','select');

  v_a6 := not has_function_privilege('anon','public.partner_licence_expiry_sweep()','execute')
      and not has_function_privilege('authenticated','public.partner_licence_expiry_sweep()','execute');

  v_ok := v_a1 and v_a2 and v_a3 and v_a4 and v_a5 and v_a6;
  return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'partner-audit doors present='||v_present::text||' (>=3)='||v_a1::text||
      ' | anon EXECUTE holes='||v_anon::text||' -> none='||v_a2::text||
      ' | authenticated still holds EXECUTE on all='||v_a3::text||
      ' | client-reachable readers of partner_audit_log with no caller check='||
        v_unguarded::text||' -> none='||v_a4::text||
      ' | the log table itself is not selectable by anon or authenticated='||v_a5::text||
      ' | the cron-only licence sweep is reachable by neither client role='||v_a6::text));
end $$;

revoke execute on function public._journey_c467_partner_audit_fence() from public, anon;
CREATE OR REPLACE FUNCTION public.dev_journey_probe(p_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_ok boolean; v_ev jsonb; v_v text; v_row record; v_jid bigint; v_pass_count int;
        v_sql text; v_chk jsonb; v_base_hash text; v_bl jsonb; v_err text;
        v_a1 boolean; v_a2 boolean; v_a3 boolean; v_a4 boolean; v_a5 boolean; v_a6 boolean;
        c_target constant text := 'my_orders_chandra_slice';
begin
  perform public._dev_guard();

  -- CMD #418 — a model provider's raw error reaching a pharmacy's till,
  -- retired as a class (see _journey_c418_provider_error).
  if p_name = 'qa-418-233' then return public._journey_c418_provider_error(); end if;


  -- CHANGE #436 — the default PUBLIC EXECUTE grant, closed as a class.
  if p_name = 'bug-436' then return public._journey_bug436(); end if;
  -- CMD #467 — the same default-PUBLIC-grant class, on the partner audit
  -- surface this command added. Writing it found the quieter half: a grant is
  -- not a guard, and admin_partner_audit_preview() had EXECUTE for every
  -- authenticated login with no role check in its body.
  if p_name = 'qa-467-323' then return public._journey_c467_partner_audit_fence(); end if;
  -- CMD #633 — a raw copy template rendered at a reader, retired as a
  -- class: cf() reports every unfilled slot on the render log.
  if p_name = 'bug-633' then return public._journey_bug633(); end if;
  -- CMD #450 — the three QA blockers this command found, each retired as a
  -- class rather than as one fix: a write action naming an event key nobody
  -- registered (both of #450's actions shipped that way), and a save-time
  -- guard that a TRIGGER walked around.
  if p_name in ('qa-450-250','qa-450-251') then
    return public._journey_c450_live_event_keys();
  end if;
  if p_name = 'qa-450-252' then return public._journey_c450_autoenable_gated(); end if;
  -- CHANGE #408 — the three QA blockers this command found, each retired as a
  -- class rather than as one screenshot: the staff binding that handed a
  -- pharmacy away, the edit window that stayed open after a supplier was
  -- asked, and the basket that was totalled on MRP.
  if p_name = 'qa-408-216' then return public._journey_c408_binding(); end if;
  if p_name = 'qa-408-217' then return public._journey_c408_window();  end if;
  if p_name = 'qa-408-218' then return public._journey_c408_pricing(); end if;
  -- CHANGE #414 — one pharmacy reading another's shelf, retired as a class:
  -- the sweep also fails on the NEXT shop-scoped function written without the
  -- fence, not just on the one that leaked.
  if p_name = 'qa-414-227' then return public._journey_c414_shop_fence(); end if;
  -- CHANGE #424 — the same class in the inference engine, caught by qa-414-227
  -- on #424 itself: an engine internal that takes a shop id must never be
  -- client-reachable, and fencing it must not fence the owner out.
  if p_name = 'qa-424-237' then return public._journey_c424_shop_fence(); end if;
  -- CHANGE #319 — QA blockers 156/157 (version.json served HTML).
  if p_name in ('qa-319-156','qa-319-157') then
    return public._journey_qa319_version();
  end if;

  -- CHANGE #240 — inquiry->PO date integrity (see _journey_bug240).
  if p_name = 'bug-240' then return public._journey_bug240(); end if;

  -- CHANGE #197 — the confirm re-read may only CONFIRM drift, never clear it.
  -- Regression guard for the false-negative: a payload target that DIFFERS on
  -- read 1 and then ERRORS on the confirm read used to vanish from both
  -- diffs.payload.changed and collection_errors, so rg_check returned ok:true
  -- while a real change sat unreported.
  if p_name = 'bug-197' then
    v_err := null;
    select position('confirm re-read failed' in p.prosrc) > 0 into v_a1
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public' and p.proname='rg_check';
    begin
      create table if not exists public._j197_ctr(n int);
      delete from public._j197_ctr where true; insert into public._j197_ctr values (0);
      execute 'create or replace function public._j197_tick() returns int language plpgsql as '
           || '$b$ declare v int; begin update public._j197_ctr set n = n + 1 where true returning n into v; '
           || 'if v >= 2 then raise exception ''j197 confirm read''; end if; return 42; end $b$';
      delete from rg_payload_targets where name = '_j197_probe';
      delete from rg_baseline where kind = 'payload' and name = '_j197_probe';
      insert into rg_payload_targets(name, sql, enabled)
        values ('_j197_probe', 'select jsonb_build_object(''v'', public._j197_tick())', true);
      insert into rg_baseline(kind, name, hash, content)
        values ('payload','_j197_probe','deadbeefdeadbeefdeadbeefdeadbeef','{"v":0}'::jsonb);

      v_chk := public.rg_check(false, true);
      select exists (select 1 from jsonb_array_elements_text(
                       coalesce(v_chk->'diffs'->'payload'->'changed','[]'::jsonb)) x
                      where x = '_j197_probe') into v_a2;
      select exists (select 1 from jsonb_array_elements(
                       coalesce(v_chk->'collection_errors','[]'::jsonb)) e
                      where e->>'name' = '_j197_probe') into v_a3;
    exception when others then
      v_a2 := false; v_a3 := false; v_err := sqlerrm;
    end;

    begin
      delete from rg_payload_targets where name = '_j197_probe';
      delete from rg_baseline where kind = 'payload' and name = '_j197_probe';
      execute 'drop function if exists public._j197_tick()';
      execute 'drop table if exists public._j197_ctr';
    exception when others then null;
    end;

    v_ok := coalesce(v_a1,false) and coalesce(v_a2,false) and coalesce(v_a3,false);
    return jsonb_build_object(
      'status', case when v_ok then 'passed' else 'failed' end,
      'evidence', jsonb_build_object(
        'db_proof',
          'rg_check carries the unconfirmable-drift rule=' || coalesce(v_a1::text,'null')
          || ' | drift KEPT in changed when the confirm read errors=' || coalesce(v_a2::text,'null')
          || ' | reason surfaced in collection_errors=' || coalesce(v_a3::text,'null'),
        'probe_cleaned_up', not exists (select 1 from rg_payload_targets where name = '_j197_probe'),
        'error', v_err));
  end if;

  -- CHANGE #192 — the mandated post-deploy verifier must never fail a run whose
  -- own asks all passed. Asserted from verify_run_log, which render_verify.js
  -- writes on every run: a run with keys_ok + build_match MUST exit 0, and a
  -- boot-only run must neither execute the allocation phase nor mutate prod.
  if p_name = 'bug-192' then
    select count(*) into v_pass_count from verify_run_log where at > now() - interval '7 days';
    if v_pass_count = 0 then
      return jsonb_build_object('status','skipped','evidence',
        jsonb_build_object('reason','no render_verify run recorded in the last 7 days'));
    end if;

    select count(*) = 0 into v_ok
    from verify_run_log l
    where l.at > now() - interval '7 days'
      and (
        (l.keys_ok and l.build_match and l.exit_code <> 0
           and coalesce(array_length(l.phases_failed,1),0) = 0)
        or (coalesce(array_length(l.requested_phases,1),0) > 0
            and exists (select 1 from unnest(l.phases_run) p
                        where not (p = any(l.requested_phases)) and p <> 'boot'))
        or (l.mutated and coalesce(array_length(l.requested_phases,1),0) > 0
            and not (l.requested_phases && array['allocation','receiving','voice','arrivals']))
      );

    select jsonb_build_object(
      'db_proof', 'verify_run_log rows/7d: '||count(*)::text||
        '; failed-with-nothing-wrong: '||
        count(*) filter (where keys_ok and build_match and exit_code <> 0
                           and coalesce(array_length(phases_failed,1),0) = 0)::text||
        '; ran-an-unrequested-phase: '||
        count(*) filter (where coalesce(array_length(requested_phases,1),0) > 0
                           and exists (select 1 from unnest(phases_run) p
                                       where not (p = any(requested_phases)) and p <> 'boot'))::text||
        '; mutated-without-asking: '||
        count(*) filter (where mutated and coalesce(array_length(requested_phases,1),0) > 0
                           and not (requested_phases && array['allocation','receiving','voice','arrivals']))::text,
      'latest', (select jsonb_build_object(
                   'at', l.at::text, 'commit', l.commit_hash, 'exit_code', l.exit_code,
                   'keys', to_jsonb(l.requested_keys),
                   'asked_for', to_jsonb(l.requested_phases),
                   'ran', to_jsonb(l.phases_run),
                   'failed', to_jsonb(l.phases_failed),
                   'mutated', l.mutated)
                 from verify_run_log l order by l.at desc limit 1))
      into v_ev
    from verify_run_log where at > now() - interval '7 days';

    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end, 'evidence', v_ev);
  end if;
  if p_name = 'backup-lands' then
    select bool_and(ok) and count(*) filter (where kind='db') >= 1
           and count(*) filter (where kind='repo') >= 1 into v_ok
    from backup_log where at > now() - interval '26 hours'
      and (size_mb)::numeric > 1 and ok;
    select jsonb_build_object(
      'db_proof', 'backup_log rows in last 26h: '||coalesce(count(*),0)::text,
      'latest', max(at)::text) into v_ev
    from backup_log where at > now() - interval '26 hours' and ok;
    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end, 'evidence', v_ev);

  elsif p_name = 'eta-honest' then
    select count(*) = 0 into v_ok
    from dev_commands
    where status='building' and eta_left_s is not null and eta_total_s is not null
      and eta_left_s > eta_total_s and coalesce(eta_note,'') = '';
    select jsonb_build_object(
      'db_proof', 'building rows: '||count(*) filter (where status='building')::text||
                  '; inflated-without-note: '||
                  count(*) filter (where status='building' and eta_left_s>eta_total_s and coalesce(eta_note,'')='')::text
    ) into v_ev from dev_commands;
    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end, 'evidence', v_ev);

  elsif p_name = 'add-media-survives' then
    select m.* into v_row from dev_command_messages m
    where jsonb_array_length(coalesce(m.images,'[]'::jsonb)) > 0
    order by m.id desc limit 1;
    if not found then
      return jsonb_build_object('status','skipped','evidence',
        jsonb_build_object('reason','no message with images yet'));
    end if;
    select bool_and(coalesce(trim(x),'') <> '') into v_ok
    from jsonb_array_elements_text(v_row.images) x;
    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end,
      'evidence', jsonb_build_object('db_proof','message #'||v_row.id||' images non-empty='||v_ok));

  elsif p_name = 'reply-media-live' then
    select m.* into v_row from dev_command_messages m
    where coalesce(m.sender,'') = 'om'
      and jsonb_array_length(coalesce(m.images,'[]'::jsonb)) > 0
    order by m.id desc limit 1;
    if not found then
      return jsonb_build_object('status','skipped','evidence',
        jsonb_build_object('reason','no reply-with-photo yet'));
    end if;
    -- c290-strengthen: presence is not content. bool_and over the paths.
    select bool_and(coalesce(trim(x),'') <> '') into v_ok
    from jsonb_array_elements_text(v_row.images) x;
    return jsonb_build_object('status', case when coalesce(v_ok,false) then 'passed' else 'failed' end,
      'evidence', jsonb_build_object('db_proof','reply message #'||v_row.id||' carries '||
        jsonb_array_length(v_row.images)::text||' image(s); every path non-empty='||
        coalesce(v_ok,false)::text));

  elsif p_name = 'android-apk-produces-file' then
    select count(*) > 0 into v_ok from dev_commands
    where android_status='built' and coalesce(android_artifact_url,'') <> '';
    if not v_ok then
      return jsonb_build_object('status','skipped','evidence',
        jsonb_build_object('reason','no built android artifact on record yet'));
    end if;
    return jsonb_build_object('status','passed','evidence',
      jsonb_build_object('db_proof','built android artifacts: '||
        (select count(*) from dev_commands where android_status='built')::text));

  elsif p_name = 'fast-lane-writes' then
    select count(*) > 0 into v_ok from ui_copy where key = 'journey.test' and value is not null;
    if not v_ok then
      return jsonb_build_object('status','skipped','evidence',
        jsonb_build_object('reason','ui_copy journey.test key not present'));
    end if;
    -- c290-strengthen: compare the exact stored value, not its nullness.
    select value = '"journey_probe_ok"'::jsonb into v_ok
      from ui_copy where key='journey.test';
    return jsonb_build_object('status', case when coalesce(v_ok,false) then 'passed' else 'failed' end,
      'evidence', jsonb_build_object('db_proof',
        'ui_copy journey.test='||(select value::text from ui_copy where key='journey.test')||
        '; equals the fast-lane marker="journey_probe_ok"='||coalesce(v_ok,false)::text));

  elsif p_name = 'gcp-taps-enqueue' then
    select count(*) > 0 into v_ok from dev_commands where kind='gcp';
    if not v_ok then
      return jsonb_build_object('status','skipped','evidence',
        jsonb_build_object('reason','no gcp-kind command on record yet'));
    end if;
    return jsonb_build_object('status','passed','evidence',
      jsonb_build_object('db_proof',
        'gcp commands on record: '||(select count(*) from dev_commands where kind='gcp')::text));

  elsif p_name = 'pool-settings-save' then
    select (select value from dev_runner_config where key='worker_pool') is not null into v_ok;
    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end,
      'evidence', jsonb_build_object(
        'db_proof', 'worker_pool config readable; sec_pin_verify(null)='||
          (sec_pin_verify(null))::text));

  elsif p_name = 'rollback-creates-command' then
    select count(*) > 0 into v_ok
    from dev_commands where title like 'Rollback #%' and urgent=true;
    if not v_ok then
      return jsonb_build_object('status','skipped','evidence',
        jsonb_build_object('reason','no Rollback command on record yet'));
    end if;
    return jsonb_build_object('status','passed','evidence',
      jsonb_build_object('db_proof',
        'urgent Rollback commands on record: '||
        (select count(*) from dev_commands where title like 'Rollback #%' and urgent=true)::text));

  elsif p_name = 'bug-191' then
    -- CHANGE #191. The class: a payload target that FAILS to collect must be
    -- reported as an explicit error, never as a content diff, and must never be
    -- written into the baseline. Previously a failure became hash='ERROR:'||md5(msg),
    -- which rg_check counted as 'changed' -> rg_gate blocked a clean tree.
    --
    -- Structural guards first (cheap, no mutation).
    select p.proconfig::text like '%statement_timeout%' into v_a1
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public' and p.proname='rg_collect_payloads';
    -- 57014 is not matched by OTHERS; it must be named or it escapes the guard.
    select p.prosrc like '%query_canceled%' into v_a2
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public' and p.proname='rg_collect_payloads';
    select not exists (select 1 from rg_baseline where kind='payload' and hash='ERROR') into v_a3;

    select b.hash into v_base_hash from rg_baseline b where b.kind='payload' and b.name=c_target;
    select pt.sql into v_sql from rg_payload_targets pt where pt.name=c_target;
    if v_sql is null or v_base_hash is null then
      return jsonb_build_object('status','skipped','evidence',
        jsonb_build_object('reason','probe target '||c_target||' is not baselined'));
    end if;

    -- Behavioural reproduction: break the target, then assert the guard's verdict.
    begin
      update rg_payload_targets set sql='select (1/0)::text::jsonb' where name=c_target;

      v_chk := rg_check(false, true);

      -- (a) the failure is surfaced as a collection error
      v_a4 := exists (select 1 from jsonb_array_elements(coalesce(v_chk->'collection_errors','[]'::jsonb)) e
                       where e->>'name' = c_target);
      -- (b) and is NOT counted as drift
      v_a5 := not exists (select 1 from jsonb_array_elements_text(
                            coalesce(v_chk->'diffs'->'payload'->'changed','[]'::jsonb)) t(nm)
                          where t.nm = c_target);

      -- (c) rebaselining while a target is failing must leave the baseline intact
      v_bl := rg_baseline_all();
      select (b.hash = v_base_hash) into v_a6
        from rg_baseline b where b.kind='payload' and b.name=c_target;

      update rg_payload_targets set sql=v_sql where name=c_target;
    exception when others then
      update rg_payload_targets set sql=v_sql where name=c_target;
      v_err := sqlerrm;
      return jsonb_build_object('status','failed','evidence',
        jsonb_build_object('db_proof','probe raised, target SQL restored: '||v_err));
    end;

    v_ok := coalesce(v_a1,false) and coalesce(v_a2,false) and coalesce(v_a3,false)
        and coalesce(v_a4,false) and coalesce(v_a5,false) and coalesce(v_a6,false);

    return jsonb_build_object(
      'status', case when v_ok then 'passed' else 'failed' end,
      'evidence', jsonb_build_object(
        'db_proof',
          'target='||c_target||
          ' | rg_collect_payloads has statement_timeout='||coalesce(v_a1,false)::text||
          ' | names query_canceled='||coalesce(v_a2,false)::text||
          ' | no ERROR hash in baseline='||coalesce(v_a3,false)::text||
          ' | broken target reported as collection_error='||coalesce(v_a4,false)::text||
          ' | broken target NOT counted as diff='||coalesce(v_a5,false)::text||
          ' | rg_baseline_all left baseline intact='||coalesce(v_a6,false)::text,
        'diffs_while_broken', coalesce(v_chk->'summary','{}'::jsonb),
        'baseline_run', coalesce(v_bl->'baselined'->'payload','null'::jsonb),
        'target_sql_restored', true));

  elsif p_name = 'qa-395-183' then
    -- CHANGE #395 QA blocker: every function that change added is SECURITY
    -- DEFINER and shipped with Postgres's default PUBLIC EXECUTE.
    -- _order_cancel_core is deliberately UNGUARDED so the token-based
    -- order-alert path can reach it, so the anon key that ships in the web
    -- bundle could cancel ANY order, release its stock and its open supplier
    -- inquiry lines, and fire an automatic refund. Same shape as
    -- feature_gaps #25, CHANGE #353 and audit_write() in #422.
    --
    -- Asserted as "the doors exist" AND "no door is open", because a
    -- bool_and over a function that has vanished is silently true.
    select count(*) = 22 into v_a1
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public'
       and p.proname in ('_order_cancel_core','_returns_guard','_return_line_money',
                         '_return_returnable_qty','_order_collected','_order_refunded',
                         '_order_paid_net','_order_rzp_payment_id','_rzp_refund_apply',
                         '_order_credit_notes','gst_ledger_build_credit_notes',
                         'refund_prepare','refund_store','returns_orders_list',
                         'order_returns_panel','order_return_add','order_return_approve',
                         'order_return_reject','refund_quote','refund_request',
                         'refund_mark_manual','refund_cancel');
    -- anon is the key in the bundle. Not one of these may be reachable by it.
    select count(*) = 0 into v_a2
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public'
       and p.proname in ('_order_cancel_core','_returns_guard','_return_line_money',
                         '_return_returnable_qty','_order_collected','_order_refunded',
                         '_order_paid_net','_order_rzp_payment_id','_rzp_refund_apply',
                         '_order_credit_notes','gst_ledger_build_credit_notes',
                         'refund_prepare','refund_store','returns_orders_list',
                         'order_returns_panel','order_return_add','order_return_approve',
                         'order_return_reject','refund_quote','refund_request',
                         'refund_mark_manual','refund_cancel')
       and has_function_privilege('anon', p.oid, 'execute');
    -- the exact door the blocker walked through
    select not has_function_privilege(
             'anon','public._order_cancel_core(uuid,text,text,uuid,text)','execute')
      into v_a3;
    -- a signed-in role may hold EXECUTE only where the function guards ITSELF.
    select count(*) = 0 into v_a4
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public'
       and p.proname in ('_order_cancel_core','_return_line_money','_return_returnable_qty',
                         '_order_collected','_order_refunded','_order_paid_net',
                         '_order_rzp_payment_id','_rzp_refund_apply',
                         'gst_ledger_build_credit_notes','refund_prepare','refund_store')
       and has_function_privilege('authenticated', p.oid, 'execute');
    -- and the ledgers themselves stay closed to the bundle key.
    select count(*) = 0 into v_a5
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname='public'
       and c.relname in ('order_returns','refunds','order_cancellations')
       and (has_table_privilege('anon', c.oid, 'insert')
         or has_table_privilege('anon', c.oid, 'update')
         or has_table_privilege('anon', c.oid, 'delete'));
    v_ok := coalesce(v_a1,false) and coalesce(v_a2,false) and coalesce(v_a3,false)
        and coalesce(v_a4,false) and coalesce(v_a5,false);
    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end,
      'evidence', jsonb_build_object('db_proof',
        'all 22 returns/refund RPCs present='||coalesce(v_a1,false)::text||
        ' | none EXECUTE-able by anon='||coalesce(v_a2,false)::text||
        ' | _order_cancel_core denied to anon='||coalesce(v_a3,false)::text||
        ' | no unguarded helper reachable by authenticated='||coalesce(v_a4,false)::text||
        ' | no returns ledger writable by anon='||coalesce(v_a5,false)::text));

  elsif p_name = 'qa-273-47' then
    -- c290-strengthen. QA #273 finding 47: the anon key that ships inside the
    -- web bundle and the APK must not reach any cron door. cron_wake matters
    -- most — it is SECURITY DEFINER, so a success there lets an anonymous
    -- caller queue dispatcher work and make the database run a task a minute.
    -- Asserted as "no door is open", and separately as "the doors still exist",
    -- because a bool_and over a vanished function is silently true.
    select count(*) = 6 into v_a1
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public'
       and p.proname in ('cron_wake','cron_dispatch','cron_run','cron_add',
                         'cron_guard_sweep','cron_health');
    -- c290-probe-fix: anon is the key that ships in the bundle, and it is the
    -- key this journey is about. A signed-in role may hold EXECUTE only where
    -- the function guards itself — cron_health does, and the super-admin Cron
    -- Health screen is built on exactly that.
    select count(*) = 0 into v_a2
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public'
       and p.proname in ('cron_wake','cron_dispatch','cron_run','cron_add',
                         'cron_guard_sweep','cron_health')
       and has_function_privilege('anon', p.oid, 'execute');
    select count(*) = 0 into v_a5
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public'
       and p.proname in ('cron_wake','cron_dispatch','cron_run','cron_add',
                         'cron_guard_sweep','cron_health')
       and has_function_privilege('authenticated', p.oid, 'execute')
       and p.prosrc not like '%_dev_guard()%';
    select not (has_function_privilege('anon','public.cron_wake(text)','execute')) into v_a3;
    select count(*) = 0 into v_a4
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname='public'
       and c.relname in ('cron_task','cron_signal','cron_guard_config','cron_dispatch_state')
       and (has_table_privilege('anon', c.oid, 'select')
         or has_table_privilege('anon', c.oid, 'insert'));
    v_ok := coalesce(v_a1,false) and coalesce(v_a2,false)
        and coalesce(v_a3,false) and coalesce(v_a4,false) and coalesce(v_a5,false);
    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end,
      'evidence', jsonb_build_object('db_proof',
        'all six cron RPCs present='||coalesce(v_a1,false)::text||
        ' | none EXECUTE-able by anon='||coalesce(v_a2,false)::text||
        ' | every signed-in-reachable cron RPC guards itself='||coalesce(v_a5,false)::text||
        ' | cron_wake denied to anon='||coalesce(v_a3,false)::text||
        ' | no cron table readable or writable by anon='||coalesce(v_a4,false)::text));

  elsif p_name = 'qa-274-57' then
    -- c290-strengthen. QA #274 finding 57: PTR must never reach an unentitled
    -- viewer. Walked as a TYPED pricing block, deliberately not as a text
    -- search: matching a formatted rupee token across 500+ cards collided with
    -- a legitimate MRP twice before and cost two false-alarm debug passes.
    v_v := coalesce(current_setting('request.jwt.claims', true), '');
    v_err := null;
    begin
      perform set_config('request.jwt.claims', '', true);   -- no session: anon
      v_chk := storefront_home_v2(60);
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
    -- c290-bool-or: aggregate the counterexample as a boolean. A count above
    -- 1 cannot be assigned to a boolean, and under the real leak the count is
    -- every card.
    select count(*),
           bool_or((card->'pricing') ?| array['ptr_display','ptr_caption','raw','has_ptr']),
           bool_or(coalesce((card->'pricing'->'card_price'->>'has_ptr')::boolean, true)),
           bool_or(coalesce(card->'pricing'->'card_price'->>'has_note','') <> 'true'
               and coalesce(card->'pricing'->'card_price'->>'note','') = ''),
           bool_or(coalesce(card->'pricing'->>'display_mode','') <> 'mrp_only')
      into v_pass_count, v_a1, v_a2, v_a3, v_a4
    from cards;

    -- c290-probe-fix: v_a1..v_a4 are booleans, so each count arrived already
    -- cast (0 -> false, n -> true). Comparing 'false' to '0' failed a clean
    -- payload every time.
    v_ok := coalesce(v_pass_count,0) > 0
        and not coalesce(v_a1,true) and not coalesce(v_a2,true)
        and not coalesce(v_a3,true) and not coalesce(v_a4,true);
    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end,
      'evidence', jsonb_build_object('db_proof',
        'anon cards walked='||coalesce(v_pass_count,0)::text||
        ' | any card leaking a ptr key='||coalesce(v_a1,true)::text||
        ' | any card with card_price.has_ptr not false='||coalesce(v_a2,true)::text||
        ' | any card missing the locked note='||coalesce(v_a3,true)::text||
        ' | any card not in display_mode=mrp_only='||coalesce(v_a4,true)::text));

  elsif p_name = 'devqueue-buttons-change-db' then
    -- c290-strengthen. "Each button flips the DB field." Asserted against the
    -- RPCs the buttons call, because the alternative — driving a real row
    -- through pause/resume/cancel — puts a decoy into the live queue that
    -- another worker can claim in the same second.
    select position($q$status='paused'$q$ in p.prosrc) > 0 into v_a1
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public' and p.proname='dev_cmd_pause';
    select position($q$status='pending'$q$ in p.prosrc) > 0 into v_a2
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public' and p.proname='dev_cmd_resume';
    select position($q$status='cancelled'$q$ in p.prosrc) > 0 into v_a3
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public' and p.proname='dev_cmd_cancel';
    select position($q$urgent = coalesce((p_patch->>'urgent')::boolean, urgent)$q$ in p.prosrc) > 0
      into v_a4
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public' and p.proname='dev_cmd_update';
    select count(*) = 4 and bool_and(p.prosrc like '%_dev_guard()%') into v_a5
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public'
       and p.proname in ('dev_cmd_pause','dev_cmd_resume','dev_cmd_cancel','dev_cmd_update');
    v_ok := coalesce(v_a1,false) and coalesce(v_a2,false) and coalesce(v_a3,false)
        and coalesce(v_a4,false) and coalesce(v_a5,false);
    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end,
      'evidence', jsonb_build_object('db_proof',
        'Pause writes paused='||coalesce(v_a1,false)::text||
        ' | Resume writes pending='||coalesce(v_a2,false)::text||
        ' | Cancel writes cancelled='||coalesce(v_a3,false)::text||
        ' | Urgent writes urgent='||coalesce(v_a4,false)::text||
        ' | all four present and guarded='||coalesce(v_a5,false)::text));

  elsif p_name = 'worker-grid-loads' then
    -- c290-strengthen. "The grid shows >=1 worker chip with lane labels."
    -- Phrased as two no-counterexample assertions so an idle box with a
    -- genuinely empty pool is not a false red: the grid must account for every
    -- command that has been building for over two minutes (the supervisor
    -- republishes every 20s, so a fresh claim is allowed to be missing), and
    -- no chip it does show may be blank.
    select value into v_chk from dev_runner_config where key='pool_state';
    if v_chk is null or jsonb_typeof(v_chk->'workers') <> 'array' then
      return jsonb_build_object('status','failed','evidence',
        jsonb_build_object('db_proof','pool_state snapshot missing or workers is not an array'));
    end if;
    select not exists (
      select 1 from dev_commands d
       where d.status='building'
         and d.id > 0   -- CHANGE #646: reserved-negative ids are rg probes
         and d.started_at < now() - interval '2 minutes'
         and not exists (select 1 from jsonb_array_elements(v_chk->'workers') w
                          where coalesce(w->>'command_id','') = d.id::text)) into v_a1;
    select not exists (
      select 1 from jsonb_array_elements(v_chk->'workers') w
       where coalesce(trim(w->>'id'),'') = ''
          or coalesce(trim(w->>'lane'),'') = ''
          or coalesce(trim(w->>'status'),'') = '') into v_a2;
    v_ok := coalesce(v_a1,false) and coalesce(v_a2,false);
    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end,
      'evidence', jsonb_build_object('db_proof',
        'chips='||jsonb_array_length(v_chk->'workers')::text||
        ' | every settled building command has a chip='||coalesce(v_a1,false)::text||
        ' | no chip missing id/lane/status='||coalesce(v_a2,false)::text));

  else
    -- Externally proven journeys (menu-reachability, qa-274-54): the assertion
    -- lives in a Playwright run or a widget test, so the only proof this branch
    -- can read is a run somebody else filed through journey_report.
    -- Check how many passed runs exist across all commands via journey_report.
    -- If >= 2, the external Playwright runner has proven this journey works → passed.
    select id into v_jid from dev_journeys where name = p_name limit 1;
    if v_jid is null then
      return jsonb_build_object('status','skipped','evidence',
        jsonb_build_object('reason','unknown journey: '||p_name));
    end if;
    -- c290-strengthen: ONLY externally reported passes count. This branch
    -- writes evidence.db_proof on its own pass, so counting every passed run
    -- let it certify itself: two journeys stood at 40 passes, 40 of them its
    -- own and 0 from any runner. An external runner (journey_report from
    -- Playwright or a widget test) files evidence WITHOUT db_proof, and that
    -- is the only proof this branch is allowed to count.
    select count(*) into v_pass_count
    from dev_journey_runs
    where journey_id = v_jid and status = 'passed'
      and not (coalesce(evidence,'{}'::jsonb) ? 'db_proof');
    if v_pass_count >= 2 then
      return jsonb_build_object('status','passed','evidence',
        jsonb_build_object('db_proof',
          'browser runner recorded '||v_pass_count||' passed runs for '||p_name));
    else
      return jsonb_build_object('status','skipped','evidence',
        jsonb_build_object('reason',
          'browser runner needs '||(2-v_pass_count)||' more run(s); current='||v_pass_count));
    end if;
  end if;
end $function$

;
