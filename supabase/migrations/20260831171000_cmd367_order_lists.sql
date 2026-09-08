-- CMD #367 · feature_gaps row 178 — named, saved order lists.
--
-- Replaces "a bulk upload screen over here and reorder subscriptions over
-- there" with one thing the pharmacy actually keeps: a named list ("Monthly
-- stock"), built from a past order or typed/pasted, edited, scheduled,
-- shared with everyone on the pharmacy account, and re-fired into the cart in
-- one tap. The typed path runs through the SAME matcher the WhatsApp bulk
-- path uses (bulk_match_items), so what the buyer confirms in the app is what
-- WhatsApp would have parsed.
--
-- "Share within the pharmacy" is modelled the way the rest of the app models
-- ownership: a list belongs to the pharmacy ACCOUNT (customer_id), and
-- shared=true makes it visible to every login on that account. shared=false
-- keeps it private to its author. There is no cross-pharmacy sharing.

create table if not exists public.order_list (
  id               uuid primary key default gen_random_uuid(),
  customer_id      uuid not null,
  name             text not null,
  created_by       uuid,
  shared           boolean not null default true,
  cadence_days     integer,
  schedule_enabled boolean not null default false,
  next_due_date    date,
  last_run_at      timestamptz,
  archived         boolean not null default false,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

create table if not exists public.order_list_item (
  id         uuid primary key default gen_random_uuid(),
  list_id    uuid not null references public.order_list(id) on delete cascade,
  product_id bigint not null,
  quantity   numeric not null default 1,
  position   integer,
  added_at   timestamptz not null default now()
);

create unique index if not exists uq_order_list_item on public.order_list_item (list_id, product_id);
create index if not exists idx_order_list_cust on public.order_list (customer_id) where archived = false;
create index if not exists idx_order_list_due  on public.order_list (next_due_date) where schedule_enabled and not archived;

alter table public.order_list      enable row level security;
alter table public.order_list_item enable row level security;

-- Reads go through the RPCs (security definer). No direct table grants: a
-- pharmacy's buying list is not something another login should be able to
-- select its way into.
revoke all on public.order_list      from anon, authenticated;
revoke all on public.order_list_item from anon, authenticated;

insert into app_settings (key, value) values
  ('order_lists_copy', jsonb_build_object(
     'title',            'Saved lists',
     'subtitle',         'Your regular buying, ready to re-fire',
     'create_label',     'New list',
     'create_hint',      'Name this list',
     'from_order_label', 'Save this order as a list',
     'empty_title',      'No saved lists yet',
     'empty_note',       'Save a past order as a list, or paste one, and reorder it in one tap.',
     'detail_empty',     'This list is empty. Add products or paste a list.',
     'add_to_cart',      'Add all to cart',
     'rename_label',     'Rename',
     'delete_label',     'Delete list',
     'share_on',         'Shared with the pharmacy',
     'share_off',        'Only you',
     'schedule_off',     'No schedule',
     'schedule_fmt',     'Every {days} days',
     'due_fmt',          'Next on {date}',
     'items_label',      'items',
     'paste_title',      'Paste a list',
     'paste_hint',       'One product per line, e.g. "Dolo 650 x 2"',
     'paste_confirm',    'Add matched items',
     'parse_matched',    'Matched',
     'parse_partial',    'Check this one',
     'parse_none',       'Not found',
     'deleted_toast',    'List deleted',
     'renamed_toast',    'List renamed',
     'saved_toast',      'List saved',
     'login_required',   'Please log in with your pharmacy account'))
on conflict (key) do nothing;

create or replace function public._ol_copy()
returns jsonb language sql stable set search_path to 'public' as $$
  select coalesce((select value from app_settings where key='order_lists_copy'), '{}'::jsonb);
$$;

-- Every mutating RPC funnels through this: it resolves the caller's pharmacy
-- AND proves the list belongs to it, so no id can be poked at from outside.
create or replace function public._ol_owned(p_id uuid)
returns public.order_list
language plpgsql stable security definer set search_path to 'public'
as $$
declare v_cust uuid := public.my_customer_id(); v_row public.order_list;
begin
  if v_cust is null then return null; end if;
  select * into v_row from public.order_list
   where id = p_id and customer_id = v_cust and archived = false;
  return v_row;
end $$;

-- ── the list screen ─────────────────────────────────────────────────────────
create or replace function public.order_list_screen()
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_copy jsonb := public._ol_copy();
  v_cust uuid  := public.my_customer_id();
  v_uid  uuid  := auth.uid();
  v_rows jsonb := '[]'::jsonb;
begin
  if v_cust is null then
    return jsonb_build_object('ok', true, 'copy', v_copy, 'has_lists', false,
      'no_customer_account', true, 'lists', '[]'::jsonb,
      'empty_title', coalesce(v_copy->>'empty_title',''),
      'empty_note',  coalesce(v_copy->>'login_required',''));
  end if;

  select coalesce(jsonb_agg(x order by x->>'updated_at' desc), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'id',            l.id::text,
      'name',          l.name,
      'item_count',    coalesce(i.n, 0),
      'count_label',   coalesce(i.n,0)::text || ' ' || coalesce(v_copy->>'items_label','items'),
      'shared',        l.shared,
      'share_label',   case when l.shared then coalesce(v_copy->>'share_on','')
                                          else coalesce(v_copy->>'share_off','') end,
      'scheduled',     l.schedule_enabled,
      'schedule_label',case when l.schedule_enabled and l.cadence_days is not null
                            then replace(coalesce(v_copy->>'schedule_fmt',''), '{days}', l.cadence_days::text)
                            else coalesce(v_copy->>'schedule_off','') end,
      'due_label',     case when l.schedule_enabled and l.next_due_date is not null
                            then replace(coalesce(v_copy->>'due_fmt',''), '{date}', to_char(l.next_due_date,'DD Mon'))
                            else '' end,
      'can_reorder',   (coalesce(i.n,0) > 0),
      'reorder_label', coalesce(v_copy->>'add_to_cart',''),
      'updated_at',    l.updated_at::text) as x
    from public.order_list l
    left join lateral (select count(*) n from public.order_list_item t where t.list_id = l.id) i on true
    where l.customer_id = v_cust
      and l.archived = false
      and (l.shared or l.created_by is null or l.created_by = v_uid)
  ) s;

  return jsonb_build_object(
    'ok', true, 'copy', v_copy,
    'title',        coalesce(v_copy->>'title',''),
    'subtitle',     coalesce(v_copy->>'subtitle',''),
    'create_label', coalesce(v_copy->>'create_label',''),
    'lists',        v_rows,
    'has_lists',    (jsonb_array_length(v_rows) > 0),
    'no_customer_account', false,
    'empty_title',  coalesce(v_copy->>'empty_title',''),
    'empty_note',   coalesce(v_copy->>'empty_note',''));
end $$;

-- ── one list, in the shape the screen prints ────────────────────────────────
create or replace function public.order_list_detail(p_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_copy jsonb := public._ol_copy();
  v_l public.order_list := public._ol_owned(p_id);
  v_items jsonb := '[]'::jsonb;
  v_total numeric := 0;
begin
  if v_l.id is null then
    return jsonb_build_object('ok', false, 'error', 'not_found',
      'copy', v_copy, 'message', coalesce(v_copy->>'login_required',''));
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'product_id',  t.product_id::text,
           'name',        coalesce(nullif(btrim(m.product_name),''), ''),
           'company',     coalesce(nullif(btrim(m.marketer),''), ''),
           'pack_label',  coalesce(nullif(btrim(m.pack_type),''), nullif(btrim(m.pack_size),''), ''),
           'image_url',   coalesce(nullif(btrim(m.image_url_1),''), ''),
           'qty',         t.quantity,
           'qty_label',   trim_scale(t.quantity)::text || ' ' ||
                          case when t.quantity = 1 then 'unit' else 'units' end,
           'buyable',     (m.buyable is true),
           'mrp_label',   coalesce(case when nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'') is not null
                                        then public.inr_money(nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric)
                                   end, ''))
         order by coalesce(t.position, 0), m.product_name), '[]'::jsonb)
    into v_items
  from public.order_list_item t
  left join "MEDICINE" m on m.id = t.product_id
  where t.list_id = v_l.id;

  return jsonb_build_object(
    'ok', true, 'copy', v_copy,
    'id',    v_l.id::text,
    'name',  v_l.name,
    'items', v_items,
    'item_count',  jsonb_array_length(v_items),
    'count_label', jsonb_array_length(v_items)::text || ' ' || coalesce(v_copy->>'items_label','items'),
    'is_empty',    (jsonb_array_length(v_items) = 0),
    'empty_note',  coalesce(v_copy->>'detail_empty',''),
    'shared',      v_l.shared,
    'share_label', case when v_l.shared then coalesce(v_copy->>'share_on','')
                                        else coalesce(v_copy->>'share_off','') end,
    'schedule', jsonb_build_object(
      'enabled',      v_l.schedule_enabled,
      'cadence_days', coalesce(v_l.cadence_days, 0),
      'label',        case when v_l.schedule_enabled and v_l.cadence_days is not null
                           then replace(coalesce(v_copy->>'schedule_fmt',''), '{days}', v_l.cadence_days::text)
                           else coalesce(v_copy->>'schedule_off','') end,
      'due_label',    case when v_l.schedule_enabled and v_l.next_due_date is not null
                           then replace(coalesce(v_copy->>'due_fmt',''), '{date}', to_char(v_l.next_due_date,'DD Mon'))
                           else '' end,
      'options',      jsonb_build_array(7, 15, 30, 45, 60)),
    'buttons', jsonb_build_array(
      jsonb_build_object('key','add_to_cart','label', coalesce(v_copy->>'add_to_cart',''),
                         'enabled', (jsonb_array_length(v_items) > 0), 'tone','brand'),
      jsonb_build_object('key','paste','label', coalesce(v_copy->>'paste_title',''),
                         'enabled', true, 'tone','neutral'),
      jsonb_build_object('key','rename','label', coalesce(v_copy->>'rename_label',''),
                         'enabled', true, 'tone','neutral'),
      jsonb_build_object('key','delete','label', coalesce(v_copy->>'delete_label',''),
                         'enabled', true, 'tone','danger')));
end $$;

-- ── create, optionally straight from a past order ───────────────────────────
create or replace function public.order_list_create(p_name text, p_from_order_id uuid default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_copy jsonb := public._ol_copy();
  v_cust uuid  := public.my_customer_id();
  v_name text  := nullif(btrim(coalesce(p_name,'')), '');
  v_id   uuid;
  v_n    int := 0;
begin
  if v_cust is null then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', coalesce(v_copy->>'login_required',''));
  end if;
  if v_name is null then
    return jsonb_build_object('ok', false, 'error','name_required',
      'message', coalesce(v_copy->>'create_hint',''));
  end if;

  insert into public.order_list (customer_id, name, created_by)
  values (v_cust, left(v_name, 60), auth.uid())
  returning id into v_id;

  if p_from_order_id is not null then
    insert into public.order_list_item (list_id, product_id, quantity, position)
    select v_id, oi.product_id, sum(coalesce(oi.quantity,1)),
           row_number() over (order by max(oi.product_name))
      from order_items oi
      join orders o on o.id = oi.order_id
     where oi.order_id = p_from_order_id
       and o.customer_id = v_cust
       and coalesce(oi.unfulfillable,false) = false
       and oi.product_id is not null
     group by oi.product_id
    on conflict (list_id, product_id) do nothing;
    get diagnostics v_n = row_count;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id::text, 'added', v_n,
    'toast', coalesce(v_copy->>'saved_toast',''),
    'detail', public.order_list_detail(v_id));
end $$;

create or replace function public.order_list_rename(p_id uuid, p_name text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_copy jsonb := public._ol_copy();
  v_l public.order_list := public._ol_owned(p_id);
  v_name text := nullif(btrim(coalesce(p_name,'')), '');
begin
  if v_l.id is null then return jsonb_build_object('ok', false, 'error','not_found'); end if;
  if v_name is null then
    return jsonb_build_object('ok', false, 'error','name_required',
      'message', coalesce(v_copy->>'create_hint','')); end if;
  update public.order_list set name = left(v_name, 60), updated_at = now() where id = v_l.id;
  return jsonb_build_object('ok', true, 'toast', coalesce(v_copy->>'renamed_toast',''),
    'detail', public.order_list_detail(v_l.id));
end $$;

-- Archive, not DELETE: a pharmacy that taps the wrong row loses nothing.
create or replace function public.order_list_delete(p_id uuid)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_copy jsonb := public._ol_copy();
  v_l public.order_list := public._ol_owned(p_id);
begin
  if v_l.id is null then return jsonb_build_object('ok', false, 'error','not_found'); end if;
  update public.order_list set archived = true, schedule_enabled = false, updated_at = now()
   where id = v_l.id;
  return jsonb_build_object('ok', true, 'toast', coalesce(v_copy->>'deleted_toast',''),
    'screen', public.order_list_screen());
end $$;

-- qty <= 0 removes the line. One RPC for add, edit and remove.
create or replace function public.order_list_item_set(p_id uuid, p_product_id bigint, p_qty numeric)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_l public.order_list := public._ol_owned(p_id);
begin
  if v_l.id is null then return jsonb_build_object('ok', false, 'error','not_found'); end if;
  if coalesce(p_qty, 0) <= 0 then
    delete from public.order_list_item where list_id = v_l.id and product_id = p_product_id;
  else
    insert into public.order_list_item (list_id, product_id, quantity)
    values (v_l.id, p_product_id, p_qty)
    on conflict (list_id, product_id) do update set quantity = excluded.quantity;
  end if;
  update public.order_list set updated_at = now() where id = v_l.id;
  return jsonb_build_object('ok', true, 'detail', public.order_list_detail(v_l.id));
end $$;

create or replace function public.order_list_share_set(p_id uuid, p_shared boolean)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_l public.order_list := public._ol_owned(p_id);
begin
  if v_l.id is null then return jsonb_build_object('ok', false, 'error','not_found'); end if;
  update public.order_list set shared = coalesce(p_shared, true), updated_at = now() where id = v_l.id;
  return jsonb_build_object('ok', true, 'detail', public.order_list_detail(v_l.id));
end $$;

create or replace function public.order_list_schedule_set(
  p_id uuid, p_cadence_days integer, p_enabled boolean)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_l public.order_list := public._ol_owned(p_id);
  v_days int := greatest(1, least(coalesce(p_cadence_days, 30), 180));
  v_on boolean := coalesce(p_enabled, false);
begin
  if v_l.id is null then return jsonb_build_object('ok', false, 'error','not_found'); end if;
  update public.order_list
     set cadence_days     = v_days,
         schedule_enabled = v_on,
         next_due_date    = case when v_on
                                 then coalesce(v_l.next_due_date,
                                       (now() at time zone 'Asia/Kolkata')::date + v_days)
                                 else null end,
         updated_at = now()
   where id = v_l.id;
  return jsonb_build_object('ok', true, 'detail', public.order_list_detail(v_l.id));
end $$;

-- ── one-tap reorder ─────────────────────────────────────────────────────────
create or replace function public.order_list_to_cart(p_id uuid)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_copy jsonb := public._ol_copy();
  v_l public.order_list := public._ol_owned(p_id);
  r record; v_added int := 0; v_skipped int := 0;
begin
  if v_l.id is null then return jsonb_build_object('ok', false, 'error','not_found'); end if;
  -- One refusing product must never cost the pharmacy the other nineteen.
  -- A line the cart declines (not buyable, or a catalog row the cart itself
  -- rejects) is counted and reported, and the rest still land.
  for r in
    select t.product_id, t.quantity, (m.buyable is true) as buyable
      from public.order_list_item t
      left join "MEDICINE" m on m.id = t.product_id
     where t.list_id = v_l.id
  loop
    if not r.buyable then
      v_skipped := v_skipped + 1;
      continue;
    end if;
    begin
      perform public.cart_set_item(r.product_id::text, greatest(1, round(r.quantity))::int, null);
      v_added := v_added + 1;
    exception when others then
      v_skipped := v_skipped + 1;
    end;
  end loop;
  return jsonb_build_object(
    'ok', true, 'added', v_added, 'skipped', v_skipped,
    'toast', v_added::text || ' ' || public._reorder_uic('reorder.added_suffix','items added to cart')
             || case when v_skipped > 0
                     then ' · ' || v_skipped::text || ' '
                          || public._reorder_uic('reorder.skipped_suffix','unavailable right now')
                     else '' end,
    'skipped_label', case when v_skipped > 0
                          then v_skipped::text || ' '
                               || public._reorder_uic('reorder.skipped_suffix','unavailable right now')
                          else '' end,
    'cart', public.cart_render(null));
end $$;

-- ── the parse-and-confirm view, shared with the WhatsApp bulk path ──────────
-- Same matcher, same statuses, so what the buyer confirms in the app is
-- exactly what reorder_wa_inbound would have understood from a WhatsApp
-- message. The screen renders these labels; it classifies nothing itself.
create or replace function public.order_list_parse(p_text text)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_copy  jsonb := public._ol_copy();
  v_items jsonb := '[]'::jsonb;
  v_line  text;
  v_qty   text;
  v_name  text;
  v_res   jsonb;
begin
  foreach v_line in array coalesce(regexp_split_to_array(coalesce(p_text,''), E'[\\n\\r]+'), array[]::text[])
  loop
    v_line := btrim(v_line);
    continue when v_line = '';
    -- "Dolo 650 x 2", "2 x Dolo 650", "Dolo 650 - 2", "Dolo 650 2"
    v_qty  := (regexp_match(v_line, '(?:[xX*]\s*|[-–]\s*|\s)(\d{1,4})\s*$'))[1];
    v_name := btrim(regexp_replace(v_line, '(?:[xX*]\s*|[-–]\s*|\s)\d{1,4}\s*$', ''));
    if v_name = '' then v_name := v_line; v_qty := null; end if;
    v_items := v_items || jsonb_build_array(
      jsonb_build_object('name', v_name, 'qty', coalesce(v_qty, '1')));
  end loop;

  if jsonb_array_length(v_items) = 0 then
    return jsonb_build_object('ok', true, 'items', '[]'::jsonb, 'count', 0,
      'copy', v_copy, 'title', coalesce(v_copy->>'paste_title',''),
      'hint', coalesce(v_copy->>'paste_hint',''),
      'confirm_label', coalesce(v_copy->>'paste_confirm',''));
  end if;

  v_res := public.bulk_match_items(v_items);

  return jsonb_build_object(
    'ok', true,
    'copy',          v_copy,
    'title',         coalesce(v_copy->>'paste_title',''),
    'hint',          coalesce(v_copy->>'paste_hint',''),
    'confirm_label', coalesce(v_copy->>'paste_confirm',''),
    'count',         jsonb_array_length(coalesce(v_res->'items','[]'::jsonb)),
    'items', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'input',       e->>'input',
               'qty',         coalesce((e->>'qty')::int, 1),
               'status',      e->>'status',
               'status_label',case e->>'status'
                                when 'matched' then coalesce(v_copy->>'parse_matched','')
                                when 'partial' then coalesce(v_copy->>'parse_partial','')
                                else coalesce(v_copy->>'parse_none','') end,
               'status_tone', case e->>'status'
                                when 'matched' then 'success'
                                when 'partial' then 'warning'
                                else 'danger' end,
               'can_add',     (e->>'status' <> 'none'),
               'preselected', (e->>'status' = 'matched'),
               'product_id',  coalesce(e->'match'->>'id',''),
               'name',        coalesce(e->'match'->>'product_name', e->>'input'),
               'company',     coalesce(e->'match'->>'company',''),
               'pack_label',  coalesce(e->'match'->>'pack_type', e->'match'->>'pack_size', ''),
               'image_url',   coalesce(e->'match'->>'image_url',''),
               'candidates',  coalesce(e->'candidates','[]'::jsonb))
             order by ord), '[]'::jsonb)
      from (select value e, ordinality ord
              from jsonb_array_elements(coalesce(v_res->'items','[]'::jsonb)) with ordinality) z));
end $$;

-- Commit a confirmed parse into the list. p_items = [{product_id, qty}, ...]
create or replace function public.order_list_add_parsed(p_id uuid, p_items jsonb)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_l public.order_list := public._ol_owned(p_id); e jsonb; v_n int := 0; v_pid bigint;
begin
  if v_l.id is null then return jsonb_build_object('ok', false, 'error','not_found'); end if;
  for e in select value from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) loop
    v_pid := nullif(btrim(coalesce(e->>'product_id','')), '')::bigint;
    continue when v_pid is null;
    insert into public.order_list_item (list_id, product_id, quantity)
    values (v_l.id, v_pid, greatest(1, coalesce((e->>'qty')::numeric, 1)))
    on conflict (list_id, product_id) do update set quantity = excluded.quantity;
    v_n := v_n + 1;
  end loop;
  update public.order_list set updated_at = now() where id = v_l.id;
  return jsonb_build_object('ok', true, 'added', v_n, 'detail', public.order_list_detail(v_l.id));
end $$;

-- ── the scheduler, on the one cron dispatcher ───────────────────────────────
create or replace function public.order_list_schedule_run()
returns integer
language plpgsql security definer set search_path to 'public'
as $$
declare l record; v_items jsonb; v_pid uuid; n int := 0;
begin
  for l in
    select * from public.order_list
     where schedule_enabled and not archived
       and next_due_date is not null
       and next_due_date <= (now() at time zone 'Asia/Kolkata')::date
  loop
    select coalesce(jsonb_agg(jsonb_build_object(
             'product_id', t.product_id::text, 'qty', t.quantity)), '[]'::jsonb)
      into v_items
    from public.order_list_item t where t.list_id = l.id;

    if jsonb_array_length(v_items) > 0 then
      v_pid := public._reorder_open_pending(l.customer_id, 'order_list', v_items, l.id);
      if v_pid is not null then
        perform public.wa_send_event('reorder_due', l.customer_id, jsonb_build_object(), null, null);
        n := n + 1;
      end if;
    end if;

    update public.order_list
       set next_due_date = (now() at time zone 'Asia/Kolkata')::date + coalesce(l.cadence_days, 30),
           last_run_at = now(), updated_at = now()
     where id = l.id;
  end loop;
  return n;
end $$;

-- Never a bare */N schedule (CHANGE #273 + the connection-exhaustion outage):
-- this rides the one dispatcher, off the minute-0 pile-up.
insert into public.cron_task (name, mode, work_sql, run_at_ist, dml, ord, enabled, note)
select 'order_list_schedule_run_daily', 'poll',
       'select public.order_list_schedule_run();',
       '06:30:00'::time, false, 565, true,
       'Fires due saved order lists into a pending reorder.'
where not exists (select 1 from public.cron_task where name = 'order_list_schedule_run_daily');

grant execute on function public.order_list_screen()                              to authenticated;
grant execute on function public.order_list_detail(uuid)                          to authenticated;
grant execute on function public.order_list_create(text, uuid)                    to authenticated;
grant execute on function public.order_list_rename(uuid, text)                    to authenticated;
grant execute on function public.order_list_delete(uuid)                          to authenticated;
grant execute on function public.order_list_item_set(uuid, bigint, numeric)       to authenticated;
grant execute on function public.order_list_share_set(uuid, boolean)              to authenticated;
grant execute on function public.order_list_schedule_set(uuid, integer, boolean)  to authenticated;
grant execute on function public.order_list_to_cart(uuid)                         to authenticated;
grant execute on function public.order_list_parse(text)                           to authenticated;
grant execute on function public.order_list_add_parsed(uuid, jsonb)               to authenticated;
