-- CMD #2060 — Customer documents: ONE three-way choice per document, per zone.
--
-- Two switches (Required, Collected) asked the admin to hold a truth table in
-- their head: required+collected, collected-only, and the two nonsense corners.
-- The document has exactly three states and they are now spelled out:
--
--   mandatory — must be uploaded; it blocks approval
--   optional  — asked for, and the customer may tick "I don't have this"
--   off       — not asked at all
--
-- And the rule is per ZONE. customer_doc_types stays the GLOBAL DEFAULT row
-- set (it already is the list of documents); customer_doc_types_zone holds one
-- override row per (zone, key). A zone with no override row for a key inherits
-- the default, so a fresh zone is correct before anyone has touched it.
--
-- required/active are kept in step with mode by a trigger so that anything not
-- yet migrated still reads the truth of the DEFAULT set.

begin;

-- ── 1. the three-way mode, on the global default set ────────────────────────
alter table public.customer_doc_types
  add column if not exists mode text;

update public.customer_doc_types
   set mode = case when required and active then 'mandatory'
                   when active              then 'optional'
                   else 'off' end
 where mode is null;

alter table public.customer_doc_types
  alter column mode set default 'optional',
  alter column mode set not null;

do $$ begin
  alter table public.customer_doc_types
    add constraint customer_doc_types_mode_chk
    check (mode in ('mandatory','optional','off'));
exception when duplicate_object then null; end $$;

-- required/active are now DERIVED. Nothing writes them directly any more, but
-- every legacy read stays true for the default set.
create or replace function public._custdoc_sync_flags() returns trigger
language plpgsql as $$
begin
  new.required := (new.mode = 'mandatory');
  new.active   := (new.mode <> 'off');
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists _custdoc_sync_flags_trg on public.customer_doc_types;
create trigger _custdoc_sync_flags_trg
  before insert or update on public.customer_doc_types
  for each row execute function public._custdoc_sync_flags();

-- ── 2. the per-zone override set ────────────────────────────────────────────
create table if not exists public.customer_doc_types_zone (
  zone_id    smallint not null references public.zones(id) on delete cascade,
  key        text     not null references public.customer_doc_types(key) on delete cascade,
  mode       text     not null check (mode in ('mandatory','optional','off')),
  updated_at timestamptz not null default now(),
  updated_by text     not null default '',
  primary key (zone_id, key)
);

create index if not exists customer_doc_types_zone_zone_idx
  on public.customer_doc_types_zone (zone_id);

alter table public.customer_doc_types_zone enable row level security;
do $$ begin
  create policy customer_doc_types_zone_read on public.customer_doc_types_zone
    for select using (true);
exception when duplicate_object then null; end $$;

-- ── 3. the resolver — the ONE place a zone's list is decided ────────────────
-- p_zone null = the global default set (what super admin edits as "Defaults").
create or replace function public.custdoc_list(p_zone smallint)
returns table (
  key text, label text, hint text, mode text, sort_order int,
  ocr_field text, camera_only boolean
)
language sql stable security definer set search_path to 'public' as $$
  select t.key, t.label, t.hint,
         coalesce(z.mode, t.mode) as mode,
         t.sort_order, t.ocr_field, t.accepts_camera_only
    from public.customer_doc_types t
    left join public.customer_doc_types_zone z
           on z.key = t.key and p_zone is not null and z.zone_id = p_zone
   order by t.sort_order, t.key;
$$;

-- The zone a KYC owner belongs to. A customer's documents follow the customer,
-- not the admin who is looking at them.
create or replace function public.custdoc_zone_for_owner(p_owner_kind text, p_owner_id uuid)
returns smallint
language sql stable security definer set search_path to 'public' as $$
  select case lower(btrim(coalesce(p_owner_kind,'')))
           when 'pharmacy' then (select zone_id from public.pharmacy_profiles where id = p_owner_id)
           when 'supplier' then (select zone_id from public.supplier_profiles where id = p_owner_id)
           else null end;
$$;

-- The signed-in customer's own zone.
create or replace function public.custdoc_my_zone()
returns smallint
language sql stable security definer set search_path to 'public' as $$
  select public.custdoc_zone_for_owner(
           public.kyc_owner_for_me()->>'owner_kind',
           nullif(public.kyc_owner_for_me()->>'owner_id','')::uuid);
$$;

commit;

-- ── 4. every word this feature prints ───────────────────────────────────────
begin;

insert into public.ui_copy (key, value) values
  ('custdoc_admin.title',            '"Customer documents"'::jsonb),
  ('custdoc_admin.subtitle',         '"Choose how each document is asked for in this zone."'::jsonb),
  ('custdoc_admin.mode.mandatory',   '"Mandatory"'::jsonb),
  ('custdoc_admin.mode.optional',    '"Optional"'::jsonb),
  ('custdoc_admin.mode.off',         '"Off"'::jsonb),
  ('custdoc_admin.note.mandatory',   '"Must be uploaded. Approval is blocked until it is."'::jsonb),
  ('custdoc_admin.note.optional',    '"Asked for. The customer may tick I don''t have this."'::jsonb),
  ('custdoc_admin.note.off',         '"Not asked for at all."'::jsonb),
  ('custdoc_admin.mode_label',       '"How it is asked"'::jsonb),
  ('custdoc_admin.zone_label',       '"Zone"'::jsonb),
  ('custdoc_admin.defaults_label',   '"Defaults"'::jsonb),
  ('custdoc_admin.defaults_note',    '"These apply to every zone that has not set its own."'::jsonb),
  ('custdoc_admin.zone_own_note',    '"This list applies to {zone} only."'::jsonb),
  ('custdoc_admin.zone_locked_note', '"You are editing your own zone."'::jsonb),
  ('custdoc_admin.inherited_label',  '"Default"'::jsonb),
  ('custdoc_admin.overridden_label', '"Changed for this zone"'::jsonb),
  ('custdoc_admin.copy_defaults',    '"Copy defaults to this zone"'::jsonb),
  ('custdoc_admin.copied',           '"Defaults copied to this zone."'::jsonb),
  ('custdoc_admin.copy_note',        '"Nothing has been set for this zone yet, so the defaults apply."'::jsonb),
  ('custdoc_admin.reset_zone',       '"Use the default"'::jsonb),
  ('custdoc_admin.reset_done',       '"Back to the default."'::jsonb),
  ('custdoc_admin.add_label',        '"Add a document"'::jsonb),
  ('custdoc_admin.add_title',        '"New document"'::jsonb),
  ('custdoc_admin.add_name',         '"What is it called?"'::jsonb),
  ('custdoc_admin.add_hint',         '"A line of help for the customer"'::jsonb),
  ('custdoc_admin.add_save',         '"Add"'::jsonb),
  ('custdoc_admin.added',            '"Document added."'::jsonb),
  ('custdoc_admin.err_name',         '"Give the document a name."'::jsonb),
  ('custdoc_admin.err_exists',       '"That document is already on the list."'::jsonb),
  ('custdoc_admin.err_super_only',   '"Only a super admin can change the list itself."'::jsonb),
  ('custdoc_admin.err_bad_mode',     '"Pick Mandatory, Optional or Off."'::jsonb),
  ('custdoc_admin.err_bad_zone',     '"That zone is not yours to edit."'::jsonb),
  ('custdoc_admin.reorder_saved',    '"New order saved."'::jsonb),
  ('custdoc_admin.reorder_hint',     '"Drag to reorder."'::jsonb),
  ('custdoc_admin.empty',            '"No documents yet."'::jsonb),
  ('custdoc_admin.saved',            '"Saved."'::jsonb),
  ('custdoc_admin.denied',           '"Only an admin can open this."'::jsonb)
on conflict (key) do update set value = excluded.value, updated_at = now();

commit;

-- ── 5. the admin surface ────────────────────────────────────────────────────
begin;

-- One card per document, and on it one three-way choice. The screen renders
-- the options it is handed; it does not know the words "mandatory" or "off".
create or replace function public.customer_doc_types_admin()
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_role   text := coalesce(public.get_my_role(),'');
  v_super  boolean := (v_role = 'super_admin');
  v_zone   smallint;
  v_zname  text;
  v_rows   jsonb;
  v_over   int := 0;
  v_note   text;
begin
  if not public.is_admin() then
    return jsonb_build_object('ok', false, 'message', public._c('custdoc_admin.denied'),
                              'items', '[]'::jsonb);
  end if;

  -- The header picker IS the zone. A partner cannot reach any other one:
  -- admin_active_zone() pins them long before this function is asked.
  v_zone := public.admin_active_zone();
  select z.name into v_zname from public.zones z where z.id = v_zone;

  select count(*) into v_over from public.customer_doc_types_zone
   where v_zone is not null and zone_id = v_zone;

  select coalesce(jsonb_agg(jsonb_build_object(
           'key', l.key, 'label', l.label, 'hint', l.hint,
           'mode', l.mode,
           'mode_label', public._c('custdoc_admin.mode.'||l.mode),
           'note', public._c('custdoc_admin.note.'||l.mode),
           'options', jsonb_build_array(
              jsonb_build_object('value','mandatory','label', public._c('custdoc_admin.mode.mandatory')),
              jsonb_build_object('value','optional', 'label', public._c('custdoc_admin.mode.optional')),
              jsonb_build_object('value','off',      'label', public._c('custdoc_admin.mode.off'))),
           'sort_order', l.sort_order,
           'camera_only', l.camera_only,
           'source', case when z.key is not null then 'zone' else 'default' end,
           'source_label', case when v_zone is null then ''
                                when z.key is not null then public._c('custdoc_admin.overridden_label')
                                else public._c('custdoc_admin.inherited_label') end,
           'can_reset', (v_zone is not null and z.key is not null),
           'reset_label', public._c('custdoc_admin.reset_zone')
         ) order by l.sort_order, l.key), '[]'::jsonb)
    into v_rows
    from public.custdoc_list(v_zone) l
    left join public.customer_doc_types_zone z
           on z.key = l.key and v_zone is not null and z.zone_id = v_zone;

  v_note := case
    when v_zone is null then public._c('custdoc_admin.defaults_note')
    when v_over = 0 then public._c('custdoc_admin.copy_note')
    else public._cf('custdoc_admin.zone_own_note',
                    jsonb_build_object('zone', coalesce(v_zname,'')))
  end;

  return jsonb_build_object('ok', true,
    'title',          public._c('custdoc_admin.title'),
    'subtitle',       public._c('custdoc_admin.subtitle'),
    'mode_label',     public._c('custdoc_admin.mode_label'),
    'zone_label',     public._c('custdoc_admin.zone_label'),
    'zone_id',        v_zone,
    'zone_name',      coalesce(v_zname, public._c('custdoc_admin.defaults_label')),
    'is_defaults',    (v_zone is null),
    'zone_note',      v_note,
    'zone_locked',    (not v_super),
    'zone_locked_note', case when v_super then '' else public._c('custdoc_admin.zone_locked_note') end,
    'can_copy_defaults', (v_zone is not null and v_over = 0),
    'copy_defaults_label', public._c('custdoc_admin.copy_defaults'),
    'can_add',        v_super,
    'add_label',      public._c('custdoc_admin.add_label'),
    'add_title',      public._c('custdoc_admin.add_title'),
    'add_name_label', public._c('custdoc_admin.add_name'),
    'add_hint_label', public._c('custdoc_admin.add_hint'),
    'add_save_label', public._c('custdoc_admin.add_save'),
    'can_reorder',    v_super,
    'reorder_hint',   case when v_super then public._c('custdoc_admin.reorder_hint') else '' end,
    'empty_line',     public._c('custdoc_admin.empty'),
    'items', v_rows, 'item_count', jsonb_array_length(v_rows));
end $$;

-- The one write the three-way choice makes. With a zone active it writes that
-- zone's override row; on Defaults it writes the default set itself.
create or replace function public.customer_doc_type_set(p_key text, p_patch jsonb)
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  v_role  text := coalesce(public.get_my_role(),'');
  v_super boolean := (v_role = 'super_admin');
  v_zone  smallint;
  v_key   text := btrim(coalesce(p_key,''));
  v_mode  text := nullif(btrim(coalesce(p_patch->>'mode','')),'');
  v_email text := lower(btrim(coalesce(auth.jwt() ->> 'email','')));
begin
  if not public.is_admin() then
    return jsonb_build_object('ok', false, 'tone','danger',
                              'message', public._c('custdoc_admin.denied'));
  end if;
  if not exists (select 1 from public.customer_doc_types where key = v_key) then
    return jsonb_build_object('ok', false, 'tone','danger',
                              'message', public._c('custdoc.err_bad_key'));
  end if;

  v_zone := public.admin_active_zone();

  -- "Use the default" — drop this zone's override and inherit again.
  if coalesce((p_patch->>'reset')::boolean, false) then
    if v_zone is null then
      return jsonb_build_object('ok', false, 'tone','danger',
                                'message', public._c('custdoc_admin.err_bad_zone'));
    end if;
    delete from public.customer_doc_types_zone where zone_id = v_zone and key = v_key;
    return jsonb_build_object('ok', true, 'tone','success',
      'message', public._c('custdoc_admin.reset_done'),
      'payload', public.customer_doc_types_admin());
  end if;

  if v_mode is not null then
    if v_mode not in ('mandatory','optional','off') then
      return jsonb_build_object('ok', false, 'tone','danger',
                                'message', public._c('custdoc_admin.err_bad_mode'));
    end if;
    if v_zone is null then
      update public.customer_doc_types set mode = v_mode where key = v_key;
    else
      insert into public.customer_doc_types_zone (zone_id, key, mode, updated_by)
      values (v_zone, v_key, v_mode, v_email)
      on conflict (zone_id, key) do update
        set mode = excluded.mode, updated_at = now(), updated_by = excluded.updated_by;
    end if;
  end if;

  -- The document itself — its name, its help line, its camera rule — is one
  -- list for the whole country, so only a super admin edits it.
  if p_patch ?| array['label','hint','camera_only','sort_order'] then
    if not v_super then
      return jsonb_build_object('ok', false, 'tone','danger',
                                'message', public._c('custdoc_admin.err_super_only'));
    end if;
    update public.customer_doc_types set
      label = coalesce(nullif(btrim(coalesce(p_patch->>'label','')),''), label),
      hint  = coalesce(p_patch->>'hint', hint),
      accepts_camera_only = coalesce((p_patch->>'camera_only')::boolean, accepts_camera_only),
      sort_order = coalesce((p_patch->>'sort_order')::int, sort_order)
     where key = v_key;
  end if;

  return jsonb_build_object('ok', true, 'tone','success',
    'message', public._c('custdoc_admin.saved'),
    'payload', public.customer_doc_types_admin());
end $$;

-- A fresh zone starts as a copy of the defaults, which is what "this zone has
-- its own list" has to mean before anyone has moved a single control.
create or replace function public.customer_doc_zone_copy_defaults()
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  v_zone smallint;
  v_email text := lower(btrim(coalesce(auth.jwt() ->> 'email','')));
begin
  if not public.is_admin() then
    return jsonb_build_object('ok', false, 'tone','danger',
                              'message', public._c('custdoc_admin.denied'));
  end if;
  v_zone := public.admin_active_zone();
  if v_zone is null then
    return jsonb_build_object('ok', false, 'tone','danger',
                              'message', public._c('custdoc_admin.err_bad_zone'));
  end if;
  insert into public.customer_doc_types_zone (zone_id, key, mode, updated_by)
  select v_zone, t.key, t.mode, v_email from public.customer_doc_types t
  on conflict (zone_id, key) do update
    set mode = excluded.mode, updated_at = now(), updated_by = excluded.updated_by;
  return jsonb_build_object('ok', true, 'tone','success',
    'message', public._c('custdoc_admin.copied'),
    'payload', public.customer_doc_types_admin());
end $$;

-- Drag to reorder. One list, one order, so a super admin owns it.
create or replace function public.customer_doc_types_reorder(p_keys text[])
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_i int := 0; v_k text;
begin
  if coalesce(public.get_my_role(),'') <> 'super_admin' then
    return jsonb_build_object('ok', false, 'tone','danger',
                              'message', public._c('custdoc_admin.err_super_only'));
  end if;
  foreach v_k in array coalesce(p_keys, '{}'::text[]) loop
    v_i := v_i + 10;
    update public.customer_doc_types set sort_order = v_i where key = v_k;
  end loop;
  return jsonb_build_object('ok', true, 'tone','success',
    'message', public._c('custdoc_admin.reorder_saved'),
    'payload', public.customer_doc_types_admin());
end $$;

create or replace function public.customer_doc_type_add(p_label text, p_hint text)
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  v_label text := btrim(coalesce(p_label,''));
  v_key   text;
  v_next  int;
begin
  if coalesce(public.get_my_role(),'') <> 'super_admin' then
    return jsonb_build_object('ok', false, 'tone','danger',
                              'message', public._c('custdoc_admin.err_super_only'));
  end if;
  if v_label = '' then
    return jsonb_build_object('ok', false, 'tone','danger',
                              'message', public._c('custdoc_admin.err_name'));
  end if;
  v_key := trim(both '_' from regexp_replace(lower(v_label), '[^a-z0-9]+', '_', 'g'));
  if v_key = '' or exists (select 1 from public.customer_doc_types where key = v_key) then
    return jsonb_build_object('ok', false, 'tone','danger',
                              'message', public._c('custdoc_admin.err_exists'));
  end if;
  select coalesce(max(sort_order),0) + 10 into v_next from public.customer_doc_types;
  insert into public.customer_doc_types (key, label, hint, mode, sort_order)
  values (v_key, v_label, coalesce(p_hint,''), 'optional', v_next);
  return jsonb_build_object('ok', true, 'tone','success',
    'message', public._c('custdoc_admin.added'),
    'payload', public.customer_doc_types_admin());
end $$;

commit;

-- ── 6. the customer side, and approval, read the SAME zone list ─────────────
begin;

create or replace function public.custdoc_mode_for(p_zone smallint, p_key text)
returns text
language sql stable security definer set search_path to 'public' as $$
  select l.mode from public.custdoc_list(p_zone) l where l.key = btrim(coalesce(p_key,''));
$$;

-- The mandatory list, for THIS owner's zone.
create or replace function public.kyc_required_kinds(p_owner_kind text, p_owner_id uuid)
returns text[]
language sql stable security definer set search_path to 'public' as $$
  select case
    when lower(btrim(coalesce(p_owner_kind,''))) = 'pharmacy'
         and exists (select 1 from public.custdoc_list(
                       public.custdoc_zone_for_owner(p_owner_kind, p_owner_id)) l
                      where l.mode = 'mandatory')
      then (select array_agg(l.key order by l.sort_order)
              from public.custdoc_list(
                     public.custdoc_zone_for_owner(p_owner_kind, p_owner_id)) l
             where l.mode = 'mandatory')
    else coalesce(
      (select array_agg(x #>> '{}')
         from jsonb_array_elements(
            coalesce((select value->'required_kinds' from public.app_settings where key='kyc_gate'),
                     '["drug_licence"]'::jsonb)) x),
      array['drug_licence'])
  end
$$;

-- The zoneless call keeps working and answers with the defaults.
create or replace function public.kyc_required_kinds(p_owner_kind text)
returns text[]
language sql stable security definer set search_path to 'public' as $$
  select public.kyc_required_kinds(p_owner_kind, null::uuid);
$$;

-- kyc_state already holds the owner id; hand it to the zone-aware overload.
-- A targeted replace, so the 120 lines this function is do not get copied into
-- a migration just to change which list it reads.
do $$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'kyc_state'
     and pg_get_function_identity_arguments(p.oid) = 'p_owner_kind text, p_owner_id uuid';
  if v_def is null then return; end if;
  if position('kyc_required_kinds(p_owner_kind, p_owner_id)' in v_def) > 0 then return; end if;
  v_def := replace(v_def, 'kyc_required_kinds(p_owner_kind)',
                          'kyc_required_kinds(p_owner_kind, p_owner_id)');
  execute v_def;
end $$;

-- The customer's own checklist. Off is not asked; mandatory offers no way out;
-- optional carries the "I don't have this" tick. The zone decides which.
create or replace function public.kyc_doc_checklist()
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_me    jsonb := public.kyc_owner_for_me();
  v_kind  text;
  v_id    uuid;
  v_zone  smallint;
  v_rows  jsonb;
  v_left  int := 0;
begin
  if not coalesce((v_me->>'has')::boolean, false) then
    return jsonb_build_object('ok', false, 'error', v_me->>'reason',
      'title', public._c('custdoc.title'),
      'step_label', public._c('custdoc.step_label'),
      'message', case v_me->>'reason'
                   when 'not_signed_in' then public._c('custdoc.err_not_signed_in')
                   else public._c('custdoc.err_no_owner') end,
      'items', '[]'::jsonb);
  end if;
  v_kind := v_me->>'owner_kind';
  v_id   := (v_me->>'owner_id')::uuid;
  v_zone := public.custdoc_zone_for_owner(v_kind, v_id);

  select coalesce(jsonb_agg(x order by x_ord), '[]'::jsonb) into v_rows from (
    select t.sort_order as x_ord, jsonb_build_object(
      'key',   t.key,
      'label', t.label,
      'hint',  t.hint,
      'mode',  t.mode,
      'required', (t.mode = 'mandatory'),
      -- A mandatory document offers no way out; that is the whole difference
      -- between the three, and it is decided here, not by the screen.
      'can_skip', (t.mode = 'optional'),
      'skip_label', case when t.mode = 'optional' then public._c('custdoc.skip_label') else '' end,
      'skipped', (coalesce(d.status,'') = 'not_available'),
      'requirement_label', case when t.mode = 'mandatory' then public._c('custdoc.required_note')
                                else public._c('custdoc.optional_note') end,
      'camera_only', t.camera_only,
      'camera_only_note', case when t.camera_only
                               then public._c('custdoc.camera_only_note') else '' end,
      'has', (d.id is not null and coalesce(d.status,'') <> 'not_available'),
      'doc_id', d.id,
      'file_name', coalesce(d.file_name,''),
      'number', coalesce(d.number,''),
      'valid_to', d.valid_to,
      'status', coalesce(d.status, 'missing'),
      'status_label', public._c('custdoc.status.'||coalesce(d.status,'missing')),
      'status_tone', case
          when coalesce(d.status,'') = 'verified' then 'success'
          when coalesce(d.status,'') = 'rejected' then 'danger'
          when coalesce(d.status,'') = 'not_available' then 'neutral'
          when d.id is null then 'warning'
          else 'info' end,
      'action_label', case when d.id is null or coalesce(d.status,'') = 'not_available'
                           then public._c('custdoc.upload_label')
                           else public._c('custdoc.replace_label') end,
      'retake_reason', case
          when d.id is null then ''
          when coalesce(t.ocr_field,'') = '' then ''
          when x.status is null or x.status = 'running' or x.status = 'queued' then ''
          when x.status = 'done'
               and nullif(btrim(coalesce(x.fields->>t.ocr_field,'')),'') is not null then ''
          when coalesce(btrim(coalesce(d.number,'')),'') <> '' then ''
          else coalesce(nullif(public._c('custdoc.unreadable.'||t.key),''),
                        public._c('custdoc.unreadable.default')) end,
      'retake_label', public._c('custdoc.retake_label')
    ) as x
      from public.custdoc_list(v_zone) t
      left join lateral (
        select * from public.kyc_documents kd
         where kd.owner_kind = v_kind and kd.owner_id = v_id and kd.kind = t.key
           and kd.status in ('pending','submitted','verified','rejected','not_available')
         order by kd.submitted_at desc nulls last, kd.created_at desc limit 1
      ) d on true
      left join lateral (
        select * from public.kyc_doc_extract e where e.doc_id = d.id
      ) x on true
     where t.mode <> 'off'
  ) q;

  select count(*) into v_left
    from public.custdoc_list(v_zone) t
   where t.mode = 'mandatory'
     and not exists (select 1 from public.kyc_documents kd
                      where kd.owner_kind = v_kind and kd.owner_id = v_id
                        and kd.kind = t.key and kd.status in ('pending','submitted','verified'));

  return jsonb_build_object(
    'ok', true,
    'bucket', 'kyc-docs',
    'upload_prefix', auth.uid()::text,
    'title', public._c('custdoc.title'),
    'step_label', public._c('custdoc.step_label'),
    'subtitle', public._c('custdoc.subtitle'),
    'close_label', public._c('custdoc.close_label'),
    'empty_line', public._c('custdoc.empty_line'),
    'zone_id', v_zone,
    'items', v_rows,
    'item_count', jsonb_array_length(v_rows),
    'required_left', v_left,
    'done', (v_left = 0),
    'summary_title', case when v_left = 0 then public._c('custdoc.done_title') else '' end,
    'summary_line', case when v_left = 0 then public._c('custdoc.done_line')
                         when v_left = 1 then public._cf('custdoc.blocked_line',
                                                jsonb_build_object('n', v_left::text))
                         else public._cf('custdoc.blocked_line_many',
                                         jsonb_build_object('n', v_left::text)) end,
    'summary_tone', case when v_left = 0 then 'success' else 'warning' end);
end $$;

-- Approval reads the customer's own zone list, not the defaults.
create or replace function public.customer_docs_missing_labels(p_customer_id uuid)
returns text
language sql stable security definer set search_path to 'public' as $$
  select coalesce(string_agg(t.label, ', ' order by t.sort_order), '')
    from public.custdoc_list(public.custdoc_zone_for_owner('pharmacy', p_customer_id)) t
   where t.mode = 'mandatory'
     and not exists (select 1 from public.kyc_documents kd
                      where kd.owner_kind = 'pharmacy' and kd.owner_id = p_customer_id
                        and kd.kind = t.key
                        and kd.status in ('pending','submitted','verified'));
$$;

create or replace function public.customer_docs_missing_sentence(p_customer_id uuid)
returns text
language sql stable security definer set search_path to 'public' as $$
  select case when count(*) = 0 then ''
              else public._cf('custdoc.approve_blocked',
                     jsonb_build_object('docs', string_agg(t.label, ', ' order by t.sort_order)))
         end
    from public.custdoc_list(public.custdoc_zone_for_owner('pharmacy', p_customer_id)) t
   where t.mode = 'mandatory'
     and not exists (select 1 from public.kyc_documents kd
                      where kd.owner_kind = 'pharmacy' and kd.owner_id = p_customer_id
                        and kd.kind = t.key and kd.status in ('pending','submitted','verified'));
$$;

commit;

-- ── 7. the remaining readers of "active / required" ─────────────────────────
begin;

create or replace function public.customer_registration_banner()
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_sess jsonb;
  v_id uuid; v_stage text; v_left int := 0; v_needs_profile boolean := false;
begin
  if auth.uid() is null then
    return jsonb_build_object('show', false);
  end if;
  begin v_sess := public.my_session(); exception when others then v_sess := '{}'::jsonb; end;
  v_needs_profile := coalesce((v_sess->>'needs_profile')::boolean, false);
  v_id := nullif(v_sess->>'customer_id','')::uuid;

  if v_needs_profile or v_id is null then
    if not v_needs_profile then return jsonb_build_object('show', false); end if;
    return jsonb_build_object(
      'show', true, 'stage', 'details',
      'title', public._c('custreg.banner_title'),
      'line',  public._c('custreg.banner_details'),
      'cta',   public._c('custreg.banner_cta'),
      'route', '/complete-registration');
  end if;

  select registration_stage::text into v_stage from public.pharmacy_profiles where id = v_id;
  if coalesce(v_stage,'') in ('approved','verified') then
    return jsonb_build_object('show', false);
  end if;

  select count(*) into v_left
    from public.custdoc_list(public.custdoc_zone_for_owner('pharmacy', v_id)) t
   where t.mode = 'mandatory'
     and not exists (select 1 from public.kyc_documents kd
                      where kd.owner_kind = 'pharmacy' and kd.owner_id = v_id
                        and kd.kind = t.key and kd.status in ('pending','submitted','verified'));

  if v_left = 0 then return jsonb_build_object('show', false); end if;

  return jsonb_build_object(
    'show', true, 'stage', 'documents', 'required_left', v_left,
    'title', public._c('custreg.banner_title'),
    'line',  public._c('custreg.banner_documents'),
    'cta',   public._c('custreg.banner_cta'),
    'route', '/customer/documents');
end $$;

-- "I don't have this" is offered by the zone's rule and refused by it too.
create or replace function public.kyc_doc_skip(p_key text, p_skip boolean default true)
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  v_me jsonb := public.kyc_owner_for_me();
  v_kind text; v_id uuid; v_zone smallint; v_key text; v_mode text;
begin
  if not coalesce((v_me->>'has')::boolean, false) then
    return jsonb_build_object('ok', false, 'tone','danger',
      'message', case v_me->>'reason'
                   when 'not_signed_in' then public._c('custdoc.err_not_signed_in')
                   else public._c('custdoc.err_no_owner') end);
  end if;
  v_kind := v_me->>'owner_kind';
  v_id   := (v_me->>'owner_id')::uuid;
  v_zone := public.custdoc_zone_for_owner(v_kind, v_id);
  v_key  := btrim(coalesce(p_key,''));
  v_mode := coalesce(public.custdoc_mode_for(v_zone, v_key), 'off');

  if v_mode = 'off' then
    return jsonb_build_object('ok', false, 'tone','danger',
      'message', public._c('custdoc.err_bad_key'));
  end if;
  if v_mode = 'mandatory' and coalesce(p_skip,true) then
    return jsonb_build_object('ok', false, 'tone','danger',
      'message', public._c('custdoc.err_required_skip'));
  end if;

  if coalesce(p_skip, true) then
    update public.kyc_documents set status = 'superseded', updated_at = now()
     where owner_kind = v_kind and owner_id = v_id and kind = v_key
       and status in ('pending','submitted','not_available');
    insert into public.kyc_documents(owner_kind, owner_id, kind, path, status,
                                     submitted_by, submitted_at, zone_id, source)
    values (v_kind, v_id, v_key, '', 'not_available', auth.uid(), now(), v_zone, 'app');
  else
    update public.kyc_documents set status = 'superseded', updated_at = now()
     where owner_kind = v_kind and owner_id = v_id and kind = v_key
       and status = 'not_available';
  end if;

  return jsonb_build_object('ok', true, 'tone','info',
    'message', case when coalesce(p_skip,true) then public._c('custdoc.skipped_toast')
                    else public._c('custdoc.unskipped_toast') end,
    'checklist', public.kyc_doc_checklist());
end $$;

-- The two upload doors ask the same question — is this document asked for in
-- THIS customer's zone — instead of reading the global active flag.
do $$
declare v_def text; f record;
begin
  for f in
    select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('customer_doc_upload_path','customer_doc_upload_register')
  loop
    v_def := pg_get_functiondef(f.oid);
    if position('custdoc_mode_for' in v_def) > 0 then continue; end if;
    v_def := replace(v_def,
      'select 1 from public.customer_doc_types where key = v_kind and active',
      'select 1 where coalesce(public.custdoc_mode_for('
        || 'public.custdoc_zone_for_owner(''pharmacy'', p_customer_id), v_kind), ''off'') <> ''off''');
    execute v_def;
  end loop;
end $$;

commit;
