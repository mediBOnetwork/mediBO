-- CHANGE #397 — Bulk actions for admin lists (part 1 of 3: the engine).
--
-- Before this, every price, availability flag, zone and status was one row at
-- a time. This adds a DATA-DRIVEN bulk engine: what may be bulk-edited lives in
-- two registry tables, so a new bulk-editable list is an INSERT, never a deploy.
--
-- Guarantees the spec asks for, in order:
--   * validate EVERY row first (all ids must exist, the value must satisfy the
--     field spec) — nothing is written until all of it passes;
--   * apply ATOMICALLY — one UPDATE inside one function call, so a failure
--     halfway leaves zero rows changed;
--   * write ONE audit entry describing the batch, plus per-row detail kept on
--     `admin_bulk_batch.before_rows` so the change can be reversed exactly.
--
-- Idempotent: every object is create-if-not-exists / create-or-replace and
-- every seed row is an upsert.

-- ── audit_log gains two additive links ───────────────────────────────────────
-- audit_log is append-only (audit_log_immutable), so an entry can never be
-- edited to say "this was undone". Instead the UNDO writes its own entry that
-- POINTS at the one it reversed, and the reader derives the state.
alter table public.audit_log add column if not exists undo_of  bigint;
alter table public.audit_log add column if not exists batch_id bigint;
create index if not exists audit_log_undo_of_idx  on public.audit_log(undo_of)  where undo_of  is not null;
create index if not exists audit_log_batch_id_idx on public.audit_log(batch_id) where batch_id is not null;

-- Which audited tables may be reversed at all. Money is never silently
-- reversed: a refund, a payment claim, a partner payout and a cancellation all
-- have their own reversal flows with their own accounting, so the generic undo
-- refuses them and says so.
alter table public.audit_table_config add column if not exists undoable boolean not null default true;
alter table public.audit_table_config add column if not exists undo_block_reason text not null default '';

update public.audit_table_config
   set undoable = false,
       undo_block_reason = 'money_reversal'
 where table_name in ('refunds','payment_claims','partner_settlement_payments',
                      'order_cancellations','billing_config');

-- ── the registry: WHAT can be bulk-edited ────────────────────────────────────
create table if not exists public.admin_bulk_target (
  key          text primary key,
  label        text        not null,
  hint         text        not null default '',
  table_name   text        not null,          -- unquoted relation name
  pk_col       text        not null,
  entity_type  text        not null,          -- ties the batch to audit_table_config
  feature_key  text        not null,          -- admin_can(feature,'write')
  name_expr    text        not null,          -- SQL expr → the row's primary line
  extra_expr   text        not null default '''''',
  filter_sql   text        not null default 'true',
  search_expr  text        not null default '''''',
  order_expr   text        not null default '1',
  extra_set    text        not null default '',  -- appended to the UPDATE's SET
  undoable     boolean     not null default true,
  require_search boolean   not null default false,  -- huge tables demand a search
  sort_order   int         not null default 100,
  is_active    boolean     not null default true
);
alter table public.admin_bulk_target add column if not exists require_search boolean not null default false;

create table if not exists public.admin_bulk_field (
  id           bigserial primary key,
  target_key   text not null references public.admin_bulk_target(key) on delete cascade,
  field        text not null,
  label        text not null,
  input_kind   text not null default 'text',  -- enum | number | bool | text
  options      jsonb not null default '[]'::jsonb,   -- [{value,label}]
  min_value    numeric,
  max_value    numeric,
  hint         text not null default '',
  confirm_body text not null default '',
  -- Columns the UPDATE also touches (bookkeeping stamps). They are snapshotted
  -- with the field and restored with it, so an undo puts back EVERY value the
  -- batch moved, not just the headline one.
  snapshot_cols text[] not null default '{}',
  extra_set    text not null default '',   -- appended to SET on apply only
  sort_order   int  not null default 100,
  is_active    boolean not null default true,
  unique (target_key, field)
);
alter table public.admin_bulk_field add column if not exists options_sql   text   not null default '';
alter table public.admin_bulk_field add column if not exists snapshot_cols text[] not null default '{}';
alter table public.admin_bulk_field add column if not exists extra_set     text   not null default '';

-- ── the ledger: what a batch DID, and how to put it back ─────────────────────
create table if not exists public.admin_bulk_batch (
  id            bigserial primary key,
  at            timestamptz not null default now(),
  actor_user_id uuid,
  actor_email   text,
  target_key    text not null,
  field         text not null,
  new_value     jsonb,
  row_count     int  not null default 0,
  before_rows   jsonb not null default '[]'::jsonb,   -- [{id, before}] per row
  audit_id      bigint,
  undone_at     timestamptz,
  undone_by     text,
  undo_audit_id bigint
);
create index if not exists admin_bulk_batch_at_idx on public.admin_bulk_batch(at desc);

alter table public.admin_bulk_target enable row level security;
alter table public.admin_bulk_field  enable row level security;
alter table public.admin_bulk_batch  enable row level security;
-- No policies: every read and write goes through the SECURITY DEFINER RPCs
-- below, which gate on admin_can(). A direct PostgREST hit sees nothing.

-- ── settings ────────────────────────────────────────────────────────────────
insert into public.app_settings(key, value) values
  ('admin.undo_window_minutes', to_jsonb(180)),
  ('admin.bulk_max_rows',       to_jsonb(500)),
  ('admin.bulk_list_limit',     to_jsonb(200))
on conflict (key) do nothing;

create or replace function public._bulk_setting(p_key text, p_default int)
returns int language sql stable security definer set search_path to 'public' as $$
  select coalesce((select (value #>> '{}')::int from public.app_settings where key = p_key), p_default);
$$;

-- ── permission features ─────────────────────────────────────────────────────
-- feature_registry.icon_key defaults to 'tile', which is NOT a row in ui_icon,
-- so the FK rejects every insert that relies on the default. Point the default
-- at a real icon so the next feature to be registered does not hit this wall.
alter table public.feature_registry alter column icon_key set default 'rule';

insert into public.feature_registry(feature_key, label, icon_key, group_label,
                                    default_access, is_active, owner, category, surface,
                                    description, search_terms, sort_order)
values ('admin.bulk_actions', 'Bulk actions', 'rule_folder', 'Tools', 'none', true, 'medibo',
        'system', 'dashboard',
        'Select many rows on an admin list and apply one change to all of them, with an undo.',
        'bulk multi select mass edit undo', 210),
       ('admin.exports', 'Exports', 'description', 'Tools', 'none', true, 'medibo',
        'system', 'dashboard',
        'Download any admin list or report as CSV or Excel with the filters currently applied.',
        'export download csv excel report', 211)
on conflict (feature_key) do update set label = excluded.label, is_active = true;

-- #396's lesson: a brand-new feature key defaults to 'none', so an admin who
-- already ran these lists loses them the moment the gate appears. Grant the two
-- new keys to whoever already holds the audit trail (the closest existing
-- capability) so nobody's access silently narrows.
insert into public.admin_permissions(admin_id, feature_key, access)
select ap.admin_id, f.k, ap.access
  from public.admin_permissions ap
  cross join (values ('admin.bulk_actions'),('admin.exports')) f(k)
 where ap.feature_key = 'admin.audit_log' and ap.access in ('read','write')
on conflict (admin_id, feature_key) do nothing;

-- ── helpers ─────────────────────────────────────────────────────────────────

-- The declared type of a column, so a text value can be cast back to it.
create or replace function public._bulk_coltype(p_table text, p_col text)
returns text language sql stable security definer set search_path to 'public' as $$
  select format_type(a.atttypid, a.atttypmod)
    from pg_attribute a
   where a.attrelid = ('public.' || quote_ident(p_table))::regclass
     and a.attname  = p_col and a.attnum > 0 and not a.attisdropped;
$$;

-- A jsonb scalar as the text Postgres will cast: json null → SQL NULL.
create or replace function public._bulk_text(p_value jsonb)
returns text language sql immutable as $$
  select case when p_value is null or jsonb_typeof(p_value) = 'null'
              then null else p_value #>> '{}' end;
$$;

-- Validates one submitted value against a field spec. Returns '' when the
-- value is acceptable, otherwise the backend's own refusal copy.
create or replace function public._bulk_validate(f public.admin_bulk_field, p_value jsonb)
returns text language plpgsql stable security definer set search_path to 'public' as $$
declare v text := public._bulk_text(p_value); v_num numeric;
begin
  if f.input_kind = 'enum' then
    if v is null then return 'Pick a value for ' || f.label || '.'; end if;
    if not exists (select 1 from jsonb_array_elements(f.options) o where o->>'value' = v) then
      return v || ' is not one of the allowed values for ' || f.label || '.';
    end if;
  elsif f.input_kind = 'number' then
    if v is null then return 'Enter a value for ' || f.label || '.'; end if;
    begin v_num := v::numeric; exception when others then
      return f.label || ' must be a number.'; end;
    if f.min_value is not null and v_num < f.min_value then
      return f.label || ' cannot be below ' || trim(to_char(f.min_value,'FM999999990.99')) || '.';
    end if;
    if f.max_value is not null and v_num > f.max_value then
      return f.label || ' cannot be above ' || trim(to_char(f.max_value,'FM999999990.99')) || '.';
    end if;
  elsif f.input_kind = 'bool' then
    if v is null or lower(v) not in ('true','false') then
      return f.label || ' must be yes or no.';
    end if;
  end if;
  return '';
end $$;

-- How a value prints in the audit entry and the result banner.
create or replace function public._bulk_value_label(f public.admin_bulk_field, p_value jsonb)
returns text language sql stable security definer set search_path to 'public' as $$
  select coalesce(
    (select o->>'label' from jsonb_array_elements(f.options) o
      where o->>'value' = public._bulk_text(p_value) limit 1),
    case when public._bulk_text(p_value) is null then 'blank'
         when f.input_kind = 'bool' then case when lower(public._bulk_text(p_value)) = 'true'
                                              then 'Yes' else 'No' end
         else public._bulk_text(p_value) end);
$$;

-- audit_log is append-only (no UPDATE), so the two new links must be set at
-- INSERT time. This is audit_write with those two columns — the original is
-- left exactly as CHANGE #394 wrote it.
create or replace function public.audit_write_ex(
  p_action text, p_entity_type text, p_entity_id text,
  p_before jsonb, p_after jsonb,
  p_batch_id bigint default null, p_undo_of bigint default null)
returns bigint language plpgsql security definer set search_path to 'public' as $$
declare v_a jsonb := public.audit_actor(); v_id bigint;
begin
  insert into public.audit_log(
    actor_user_id, actor_email, actor_role, action, entity_type, entity_id,
    before, after, changed_keys, zone_id, source, ip, batch_id, undo_of)
  values (
    (v_a->>'user_id')::uuid, v_a->>'email', v_a->>'role',
    p_action, p_entity_type, p_entity_id, p_before, p_after,
    case when p_before is not null and p_after is not null then
      (select coalesce(array_agg(k order by k), '{}')
         from (select jsonb_object_keys(p_after) as k) s
        where (p_after->s.k) is distinct from (p_before->s.k))
    end,
    nullif(v_a->>'zone_id','')::smallint, v_a->>'source', v_a->>'ip',
    p_batch_id, p_undo_of)
  returning id into v_id;
  return v_id;
end $$;


-- ── the screen payload ──────────────────────────────────────────────────────
-- One RPC, every string on the page. Dart renders it and decides nothing.
create or replace function public.admin_bulk_screen(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_target text := nullif(btrim(coalesce(p->>'target','')),'');
  v_search text := nullif(btrim(coalesce(p->>'search','')),'');
  v_limit  int  := public._bulk_setting('admin.bulk_list_limit', 200);
  t        public.admin_bulk_target;
  v_rows   jsonb := '[]'::jsonb;
  v_total  bigint := 0;
  v_targets jsonb;
  v_fields  jsonb := '[]'::jsonb;
  v_opts    jsonb;
  f         record;
  v_needs   boolean := false;
begin
  if not public.admin_can('admin.bulk_actions','read') then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'title',   'Bulk actions & exports',
      'message', 'You do not have access to bulk actions. Ask a super admin to grant you the Bulk actions permission.');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('key', x.key, 'label', x.label, 'hint', x.hint)
           order by x.sort_order, x.label), '[]'::jsonb)
    into v_targets
    from public.admin_bulk_target x
   where x.is_active and public.admin_can(x.feature_key,'read');

  if v_target is null then v_target := (v_targets->0->>'key'); end if;

  select * into t from public.admin_bulk_target
   where key = v_target and is_active and public.admin_can(feature_key,'read');

  if t.key is not null then
    -- Field specs, with dynamic option lists resolved server-side (a zone list
    -- is a table, not a constant, so it must not be frozen into the registry).
    for f in select * from public.admin_bulk_field
              where target_key = t.key and is_active
              order by sort_order, label loop
      v_opts := f.options;
      if btrim(f.options_sql) <> '' then
        execute format(
          'select coalesce(jsonb_agg(jsonb_build_object(''value'', o.value::text, ''label'', o.label::text)), ''[]''::jsonb) from (%s) o',
          f.options_sql) into v_opts;
      end if;
      v_fields := v_fields || jsonb_build_array(jsonb_build_object(
        'field', f.field, 'label', f.label, 'input_kind', f.input_kind,
        'options', coalesce(v_opts,'[]'::jsonb), 'hint', f.hint,
        'confirm_body', f.confirm_body, 'min', f.min_value, 'max', f.max_value));
    end loop;

    -- A 500k-row catalogue is never listed whole: the target says so and the
    -- screen prints the backend's own instruction instead of a spinner.
    v_needs := t.require_search and v_search is null;

    if not v_needs then
      execute format($f$
        with hit as (
          select t.%1$I::text as id, (%2$s)::text as name, (%3$s)::text as extra
            from public.%4$I t
           where (%5$s)
             and ($1 is null or (%6$s)::text ilike '%%' || $1 || '%%')
           order by (%2$s)::text
           limit %7$s
        )
        select coalesce((select jsonb_agg(to_jsonb(h) order by h.name) from hit h), '[]'::jsonb),
               (select count(*) from hit)
      $f$, t.pk_col, t.name_expr, t.extra_expr, t.table_name, t.filter_sql,
           t.search_expr, v_limit)
      into v_rows, v_total using v_search;
    end if;
  end if;

  return jsonb_build_object(
    'ok', true,
    'title',        'Bulk actions & exports',
    'subtitle',     'Select rows, apply one change to all of them, and undo it if it was wrong.',
    'can_write',    public.admin_can('admin.bulk_actions','write'),
    'tab_bulk',     'Bulk edit',
    'tab_export',   'Exports',
    'tab_history',  'History',
    'targets',      v_targets,
    'target',       coalesce(t.key, ''),
    'target_label', coalesce(t.label, ''),
    'target_hint',  coalesce(t.hint, ''),
    'fields',       v_fields,
    'rows',         v_rows,
    'count',        v_total,
    'needs_search', v_needs,
    'count_label',  case when v_needs then ''
                    else v_total::text || case when v_total = 1 then ' row' else ' rows' end
                         || case when v_total >= v_limit
                                 then ' · showing the first ' || v_limit::text else '' end end,
    'search_hint',  case when coalesce(t.require_search,false)
                         then 'Type a name to search this list'
                         else 'Search this list' end,
    'needs_search_title', 'Search first',
    'needs_search_hint',  'This list is too large to show in full. Type at least part of a name above.',
    'select_all_label', 'Select all shown',
    'clear_label',  'Clear',
    'apply_label',  'Apply to selected',
    'field_label',  'Change',
    'value_label',  'New value',
    'cancel_label', 'Cancel',
    'confirm_cta',  'Apply change',
    'sheet_title',  'Apply one change to every selected row',
    'max_rows',     public._bulk_setting('admin.bulk_max_rows', 500),
    'empty_title',  'Nothing to show',
    'empty_hint',   'No rows match this search. Clear it to see the list again.',
    'no_selection_hint', 'Tick the rows you want to change.',
    'selected_fmt', '{n} selected');
end $$;

-- ── the engine ──────────────────────────────────────────────────────────────
-- Validate everything, then apply everything, then record it once.
create or replace function public.admin_bulk_apply(
  p_target text, p_ids jsonb, p_field text, p_value jsonb,
  p_preview boolean default false)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  t         public.admin_bulk_target;
  f         public.admin_bulk_field;
  v_ids     text[];
  v_cols    text[];
  v_max     int := public._bulk_setting('admin.bulk_max_rows', 500);
  v_found   int;
  v_msg     text;
  v_before  jsonb;
  v_coltype text;
  v_val     text := public._bulk_text(p_value);
  v_set     text;
  v_n       int;
  v_batch   bigint;
  v_audit   bigint;
  v_label   text;
begin
  select * into t from public.admin_bulk_target where key = p_target and is_active;
  if t.key is null then
    return jsonb_build_object('ok', false, 'message', 'That list cannot be bulk-edited.');
  end if;
  if not public.admin_can('admin.bulk_actions','write') or not public.admin_can(t.feature_key,'write') then
    return jsonb_build_object('ok', false,
      'message', 'You do not have write access to ' || t.label || '.');
  end if;

  select * into f from public.admin_bulk_field
   where target_key = t.key and field = p_field and is_active;
  if f.id is null then
    return jsonb_build_object('ok', false, 'message', 'That field cannot be bulk-edited.');
  end if;

  select coalesce(array_agg(distinct e), '{}') into v_ids
    from jsonb_array_elements_text(coalesce(p_ids,'[]'::jsonb)) e;

  if cardinality(v_ids) = 0 then
    return jsonb_build_object('ok', false, 'message', 'Select at least one row first.');
  end if;
  if cardinality(v_ids) > v_max then
    return jsonb_build_object('ok', false,
      'message', 'Too many rows at once — ' || cardinality(v_ids)::text ||
                 ' selected, the limit is ' || v_max::text || '.');
  end if;

  v_msg := public._bulk_validate(f, p_value);
  if v_msg <> '' then
    return jsonb_build_object('ok', false, 'message', v_msg);
  end if;

  v_coltype := public._bulk_coltype(t.table_name, f.field);
  if v_coltype is null then
    return jsonb_build_object('ok', false, 'message', 'That field no longer exists.');
  end if;

  -- The columns this batch will move: the field itself plus every bookkeeping
  -- stamp the SET clause touches. All of them are snapshotted, so the undo can
  -- put back EVERY value the batch changed.
  v_cols := array[f.field] || coalesce(f.snapshot_cols, '{}');

  -- EVERY row is validated before ANY row is written: snapshot each selected
  -- row and refuse the whole batch if even one of them cannot be found.
  execute format(
    'select coalesce(jsonb_agg(jsonb_build_object(
              ''id'',     t.%1$I::text,
              ''name'',   (%4$s)::text,
              ''before'', (select jsonb_object_agg(k.c, to_jsonb(t) -> k.c)
                             from unnest(%6$L::text[]) as k(c)))), ''[]''::jsonb)
       from public.%3$I t where t.%1$I::text = any($1) and (%5$s)',
    t.pk_col, f.field, t.table_name, t.name_expr, t.filter_sql, v_cols)
    into v_before using v_ids;

  v_found := jsonb_array_length(v_before);
  if v_found <> cardinality(v_ids) then
    return jsonb_build_object('ok', false,
      'message', 'Nothing was changed — ' || (cardinality(v_ids) - v_found)::text ||
                 ' of the ' || cardinality(v_ids)::text ||
                 ' selected rows could not be found. Reload the list and try again.');
  end if;

  v_label := public._bulk_value_label(f, p_value);

  if coalesce(p_preview,false) then
    return jsonb_build_object('ok', true, 'preview', true, 'row_count', v_found,
      'message', 'Set ' || f.label || ' to ' || v_label || ' on ' || v_found::text ||
                 case when v_found = 1 then ' row?' else ' rows?' end);
  end if;

  v_set := '';
  if btrim(t.extra_set) <> '' then v_set := v_set || ', ' || t.extra_set; end if;
  if btrim(f.extra_set) <> '' then v_set := v_set || ', ' || f.extra_set; end if;

  -- One statement, one transaction: it lands on every row or on none.
  execute format(
    'update public.%1$I t set %2$I = $1::text::%3$s%6$s where t.%4$I::text = any($2) and (%5$s)',
    t.table_name, f.field, v_coltype, t.pk_col, t.filter_sql, v_set)
    using v_val, v_ids;
  get diagnostics v_n = row_count;

  insert into public.admin_bulk_batch(
      actor_user_id, actor_email, target_key, field, new_value, row_count, before_rows)
  values ((public.audit_actor()->>'user_id')::uuid, public.audit_actor()->>'email',
          t.key, f.field, p_value, v_n, v_before)
  returning id into v_batch;

  -- ONE audit entry for the batch. The per-row detail rides in before/after so
  -- the trail can still answer "which rows, and what were they?" years later.
  v_audit := public.audit_write_ex(
    'bulk.' || t.key || '.' || f.field,
    t.entity_type,
    'batch:' || v_batch::text,
    jsonb_build_object('rows', v_before, 'field', f.field, 'label', f.label),
    jsonb_build_object('value', p_value, 'value_label', v_label,
                       'row_count', v_n, 'field', f.field, 'label', f.label,
                       'target', t.key, 'target_label', t.label),
    v_batch, null);

  update public.admin_bulk_batch set audit_id = v_audit where id = v_batch;

  return jsonb_build_object(
    'ok', true, 'batch_id', v_batch, 'audit_id', v_audit, 'row_count', v_n,
    'message', f.label || ' set to ' || v_label || ' on ' || v_n::text ||
               case when v_n = 1 then ' row.' else ' rows.' end,
    'undo_label', 'Undo',
    'undo_hint',  'Undo puts all ' || v_n::text || ' rows back to the values they had a moment ago.');
end $$;

-- ── undo a batch ────────────────────────────────────────────────────────────
create or replace function public.admin_bulk_undo(p_batch_id bigint)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  b         public.admin_bulk_batch;
  t         public.admin_bulk_target;
  f         public.admin_bulk_field;
  v_window  int := public._bulk_setting('admin.undo_window_minutes', 180);
  v_cols    text[];
  v_set     text := '';
  v_col     text;
  v_type    text;
  v_n       int;
  v_after   jsonb;
  v_audit   bigint;
begin
  select * into b from public.admin_bulk_batch where id = p_batch_id;
  if b.id is null then
    return jsonb_build_object('ok', false, 'message', 'That batch no longer exists.');
  end if;
  if b.undone_at is not null then
    return jsonb_build_object('ok', false, 'message', 'That change was already undone.');
  end if;

  select * into t from public.admin_bulk_target where key = b.target_key;
  if t.key is null or not t.undoable then
    return jsonb_build_object('ok', false, 'message', 'This kind of change cannot be undone here.');
  end if;
  if not public.admin_can('admin.bulk_actions','write') or not public.admin_can(t.feature_key,'write') then
    return jsonb_build_object('ok', false,
      'message', 'You do not have write access to ' || t.label || '.');
  end if;
  if b.at < now() - make_interval(mins => v_window) then
    return jsonb_build_object('ok', false,
      'message', 'The undo window for this change closed after ' || v_window::text || ' minutes.');
  end if;

  select * into f from public.admin_bulk_field where target_key = t.key and field = b.field;
  v_cols := array[b.field] || coalesce(f.snapshot_cols, '{}');

  -- Restore every column the batch moved, each cast back to its own type.
  foreach v_col in array v_cols loop
    v_type := public._bulk_coltype(t.table_name, v_col);
    if v_type is null then
      return jsonb_build_object('ok', false,
        'message', 'The ' || v_col || ' field no longer exists, so this change cannot be reversed.');
    end if;
    v_set := v_set || case when v_set = '' then '' else ', ' end ||
             format('%I = (r.before -> %L #>> ''{}'')::%s', v_col, v_col, v_type);
  end loop;

  -- What the rows look like NOW, so the undo's own audit entry is honest about
  -- what it replaced.
  execute format(
    'select coalesce(jsonb_agg(jsonb_build_object(
              ''id'', t.%1$I::text,
              ''before'', (select jsonb_object_agg(k.c, to_jsonb(t) -> k.c)
                             from unnest(%3$L::text[]) as k(c)))), ''[]''::jsonb)
       from public.%2$I t
      where t.%1$I::text in (select r->>''id'' from jsonb_array_elements($1) r)',
    t.pk_col, t.table_name, v_cols) into v_after using b.before_rows;

  execute format(
    'update public.%1$I t set %2$s
       from jsonb_to_recordset($1) as r(id text, before jsonb)
      where t.%3$I::text = r.id',
    t.table_name, v_set, t.pk_col) using b.before_rows;
  get diagnostics v_n = row_count;

  -- Nothing is ever silently reversed: the undo gets its OWN audit entry,
  -- linked to the entry it reversed.
  v_audit := public.audit_write_ex(
    'undo.bulk.' || t.key || '.' || b.field,
    t.entity_type,
    'batch:' || b.id::text,
    jsonb_build_object('rows', v_after, 'field', b.field),
    jsonb_build_object('rows', b.before_rows, 'field', b.field,
                       'row_count', v_n, 'target', t.key, 'target_label', t.label,
                       'restored', true),
    b.id, b.audit_id);

  update public.admin_bulk_batch
     set undone_at = now(), undone_by = public.audit_actor()->>'email',
         undo_audit_id = v_audit
   where id = b.id;

  return jsonb_build_object('ok', true, 'row_count', v_n, 'audit_id', v_audit,
    'message', v_n::text || case when v_n = 1 then ' row' else ' rows' end ||
               ' put back to the values held before that change.');
end $$;

-- ── batch history (the History tab, and the Undo chip's source of truth) ────
create or replace function public.admin_bulk_batches(p_limit int default 30)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_rows jsonb; v_window int := public._bulk_setting('admin.undo_window_minutes', 180);
begin
  if not public.admin_can('admin.bulk_actions','read') then
    return jsonb_build_object('ok', false,
      'message', 'You do not have access to bulk actions.');
  end if;

  select coalesce(jsonb_agg(s.x order by s.sid desc), '[]'::jsonb) into v_rows from (
    select b.id as sid, jsonb_build_object(
      'id',          b.id,
      'title',       coalesce(t.label, b.target_key) || ' · ' || coalesce(f.label, b.field),
      'value_label', 'Set to ' || coalesce(public._bulk_value_label(f, b.new_value),
                                           coalesce(b.new_value #>> '{}', 'blank')),
      'count_label', b.row_count::text || case when b.row_count = 1 then ' row' else ' rows' end,
      'actor_label', coalesce(nullif(b.actor_email,''), 'System'),
      'when_label',  public._audit_when(b.at),
      'tone',        case when b.undone_at is not null then 'warning' else 'success' end,
      'state_label', case when b.undone_at is not null
                          then 'Undone ' || public._audit_when(b.undone_at) else 'Applied' end,
      'can_undo',    b.undone_at is null
                     and coalesce(t.undoable, false)
                     and b.at >= now() - make_interval(mins => v_window)
                     and public.admin_can('admin.bulk_actions','write')
                     and public.admin_can(coalesce(t.feature_key,'admin.bulk_actions'),'write'),
      'undo_label',  'Undo',
      'undo_blocked_label', case
        when b.undone_at is not null then 'Already undone'
        when not coalesce(t.undoable, false) then 'Not reversible here'
        when b.at < now() - make_interval(mins => v_window) then 'Undo window closed'
        else '' end,
      'confirm_title', 'Undo this change?',
      'confirm_body',  'All ' || b.row_count::text ||
                       ' rows go back to the values they held before. The undo is itself recorded.',
      'confirm_cta',   'Undo change',
      'cancel_label',  'Keep it') as x
      from public.admin_bulk_batch b
      left join public.admin_bulk_target t on t.key = b.target_key
      left join public.admin_bulk_field  f on f.target_key = b.target_key and f.field = b.field
     order by b.id desc limit greatest(coalesce(p_limit,30),1)) s;

  return jsonb_build_object('ok', true, 'rows', v_rows,
    'title',        'Recent bulk changes',
    'window_label', 'Undo stays available for ' || v_window::text || ' minutes after a change.',
    'empty_title',  'No bulk changes yet',
    'empty_hint',   'Apply a change from the Bulk edit tab and it is listed here with an Undo.');
end $$;

grant execute on function public.audit_write_ex(text, text, text, jsonb, jsonb, bigint, bigint) to authenticated;
grant execute on function public.admin_bulk_screen(jsonb)   to authenticated;
grant execute on function public.admin_bulk_apply(text, jsonb, text, jsonb, boolean) to authenticated;
grant execute on function public.admin_bulk_undo(bigint)    to authenticated;
grant execute on function public.admin_bulk_batches(int)    to authenticated;
