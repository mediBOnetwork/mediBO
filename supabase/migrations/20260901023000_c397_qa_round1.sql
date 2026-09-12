-- CHANGE #397 — QA round 1 fixes.
--
-- The hostile pass found two real defects in the engine, both in the same
-- blind spot: the validator and the value-labeller read `admin_bulk_field.options`
-- (the STATIC column) and never resolved `options_sql`.
--
--  1. Zone — the one field whose options are a TABLE — could not be set at all.
--     Every attempt came back "1 is not one of the allowed values for Zone",
--     because the static options list for that field is deliberately empty.
--     The screen offered a dropdown the engine would always refuse.
--  2. Even when a dynamic value was accepted, the audit entry and the result
--     banner would print the raw stored value ("2") rather than the label the
--     admin actually picked ("Bilaspur Zone").
--
-- Both are fixed by resolving the option list in ONE place that both callers
-- use. Third fix: a numeric bound printed as "cannot be above 1000000.." —
-- the FM mask left a trailing decimal point and the sentence added its own.

-- The option list for a field, whichever way it is defined.
create or replace function public._bulk_options(f public.admin_bulk_field)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v jsonb;
begin
  if f.options_sql is null or btrim(f.options_sql) = '' then
    return coalesce(f.options, '[]'::jsonb);
  end if;
  execute format(
    'select coalesce(jsonb_agg(jsonb_build_object(''value'', o.value::text, ''label'', o.label::text)), ''[]''::jsonb) from (%s) o',
    f.options_sql) into v;
  return coalesce(v, '[]'::jsonb);
end $$;

-- A number the way a person writes it. The FM mask drops trailing ZEROS but
-- keeps the decimal POINT, so 1000000 came out as "1000000." and the sentence
-- that appended its own full stop read "cannot be above 1000000..".
create or replace function public._bulk_num(p numeric)
returns text language sql immutable as $$
  select rtrim(rtrim(trim(to_char(p, 'FM9999999990.99')), '0'), '.');
$$;

create or replace function public._bulk_validate(f public.admin_bulk_field, p_value jsonb)
returns text language plpgsql stable security definer set search_path to 'public' as $$
declare v text := public._bulk_text(p_value); v_num numeric; v_opts jsonb;
begin
  if f.input_kind = 'enum' then
    if v is null then return 'Pick a value for ' || f.label || '.'; end if;
    v_opts := public._bulk_options(f);
    if not exists (select 1 from jsonb_array_elements(v_opts) o where o->>'value' = v) then
      return v || ' is not one of the allowed values for ' || f.label || '.';
    end if;
  elsif f.input_kind = 'number' then
    if v is null then return 'Enter a value for ' || f.label || '.'; end if;
    begin v_num := v::numeric; exception when others then
      return f.label || ' must be a number.'; end;
    if f.min_value is not null and v_num < f.min_value then
      return f.label || ' cannot be below ' || public._bulk_num(f.min_value) || '.';
    end if;
    if f.max_value is not null and v_num > f.max_value then
      return f.label || ' cannot be above ' || public._bulk_num(f.max_value) || '.';
    end if;
  elsif f.input_kind = 'bool' then
    if v is null or lower(v) not in ('true','false') then
      return f.label || ' must be yes or no.';
    end if;
  end if;
  return '';
end $$;

create or replace function public._bulk_value_label(f public.admin_bulk_field, p_value jsonb)
returns text language sql stable security definer set search_path to 'public' as $$
  select coalesce(
    (select o->>'label' from jsonb_array_elements(public._bulk_options(f)) o
      where o->>'value' = public._bulk_text(p_value) limit 1),
    case when public._bulk_text(p_value) is null then 'blank'
         when f.input_kind = 'bool' then case when lower(public._bulk_text(p_value)) = 'true'
                                              then 'Yes' else 'No' end
         else public._bulk_text(p_value) end);
$$;

-- The screen builds its dropdowns from the same resolver, so what it offers and
-- what the engine accepts can no longer drift apart.
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
  f         public.admin_bulk_field;
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
    for f in select * from public.admin_bulk_field
              where target_key = t.key and is_active
              order by sort_order, label loop
      v_fields := v_fields || jsonb_build_array(jsonb_build_object(
        'field', f.field, 'label', f.label, 'input_kind', f.input_kind,
        'options', public._bulk_options(f), 'hint', f.hint,
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

-- The selftest grows a case for exactly the defect that escaped it: a field
-- whose options come from a table must be settable, and must print its LABEL.
create or replace function public.admin_bulk_dynamic_option_selftest()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  f      public.admin_bulk_field;
  v_zone text;
  v_msg  text;
  v_lbl  text;
begin
  if coalesce(auth.jwt() ->> 'role','') <> 'service_role'
     and not public.admin_can('admin.bulk_actions','write') then
    return jsonb_build_object('ok', false, 'message', 'not_authorized');
  end if;

  select * into f from public.admin_bulk_field
   where target_key = 'customer_records' and field = 'zone_id';
  select id::text into v_zone from public.zones where is_active order by id limit 1;

  v_msg := public._bulk_validate(f, to_jsonb(v_zone));
  v_lbl := public._bulk_value_label(f, to_jsonb(v_zone));

  return jsonb_build_object(
    'ok', v_msg = '' and v_lbl <> v_zone,
    'zone', v_zone, 'validation', v_msg, 'label', v_lbl,
    'message', case when v_msg = '' and v_lbl <> v_zone
      then 'A table-backed option validates and prints its label (' || v_lbl || ').'
      else 'dynamic options still broken: validation="' || v_msg || '" label="' || v_lbl || '"' end);
end $$;

grant execute on function public.admin_bulk_dynamic_option_selftest() to authenticated;
