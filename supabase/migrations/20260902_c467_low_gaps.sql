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
