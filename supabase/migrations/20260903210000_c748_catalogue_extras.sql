-- CHANGE #748 — Catalogue extras: Recently added, Missing product request, and
-- a price-free catalogue export.
--
-- ── 1. When a product entered the catalogue ────────────────────────────────
--
-- "MEDICINE" has 563k rows and no created_at. Adding a NULLABLE column with no
-- default is a catalogue-only change in Postgres - instant, no table rewrite -
-- so the DDL is cheap; the honest part is the BACKFILL.
--
-- There is no per-row import log. The id order is insertion order but carries
-- no date, so stamping every row from it would invent 563k timestamps and make
-- "Recently added" a fiction. Rows that entered through
-- admin_approve_pending_medicine DO have a real date on the pending row, and
-- those are the only ones backfilled. Everything else stays NULL and is
-- correctly not recent. The DEFAULT means every row from today forward is
-- stamped, so the feature is right going forward and never lies about the past.
alter table public."MEDICINE"
  add column if not exists created_at timestamptz;

alter table public."MEDICINE"
  alter column created_at set default now();

-- Partial: only the rows that HAVE a date are ever scanned for "recent", so the
-- index stays tiny against a 563k-row table instead of indexing 563k NULLs.
create index if not exists medicine_created_at_idx
  on public."MEDICINE" (created_at desc)
  where created_at is not null;

-- The backfill: only rows whose date is actually KNOWN. Matched on the name the
-- approver wrote into "MEDICINE", which is the same string the approve function
-- inserted. Bounded by the pending table (hundreds of rows, not 563k), so this
-- is a small write and not a bulk one.
update public."MEDICINE" m
   set created_at = p.created_at
  from (select lower(btrim(product_name)) as nm, min(created_at) as created_at
          from public.supplier_pending_medicines
         where status = 'approved'
         group by 1) p
 where m.created_at is null
   and lower(btrim(m.product_name)) = p.nm;

-- ── 2. Config + copy ───────────────────────────────────────────────────────
create table if not exists public.catalogue_extras_config (
  id             smallint primary key default 1,
  new_days       integer not null default 30,
  export_max     integer not null default 500,
  request_open   boolean not null default true,
  updated_at     timestamptz not null default now()
);
insert into public.catalogue_extras_config (id) values (1) on conflict (id) do nothing;

insert into public.ui_copy (key, value) values
  ('catalogue.new_badge',        '"New"'::jsonb),
  ('catalogue.recent_title',     '"Recently added"'::jsonb),
  ('catalogue.recent_sub',       '"Products added to the catalogue in the last %s days"'::jsonb),
  ('catalogue.recent_empty',     '"Nothing new in this window yet."'::jsonb),
  ('catalogue.recent_count',     '"%s product(s)"'::jsonb),
  ('catalogue.request_title',    '"Missing product?"'::jsonb),
  ('catalogue.request_sub',      '"Tell us what you could not find and we will add it."'::jsonb),
  ('catalogue.request_name',     '"Product name"'::jsonb),
  ('catalogue.request_company',  '"Company"'::jsonb),
  ('catalogue.request_salt',     '"Salt / composition"'::jsonb),
  ('catalogue.request_pack',     '"Pack"'::jsonb),
  ('catalogue.request_photo',    '"Add a photo (optional)"'::jsonb),
  ('catalogue.request_submit',   '"Send request"'::jsonb),
  ('catalogue.request_sent',     '"Thanks — we will add it and let you know."'::jsonb),
  ('catalogue.request_closed',   '"Requests are paused right now."'::jsonb),
  ('catalogue.request_need_name','"Please enter the product name."'::jsonb),
  ('catalogue.request_dupe',     '"We already have this — here it is."'::jsonb),
  ('catalogue.request_dupe_cta', '"Open it"'::jsonb),
  ('catalogue.request_mine',     '"Your requests"'::jsonb),
  ('catalogue.request_pending',  '"Being checked"'::jsonb),
  ('catalogue.request_approved', '"Added to the catalogue"'::jsonb),
  ('catalogue.request_rejected', '"Not added"'::jsonb),
  ('catalogue.export_title',     '"Print / share my catalogue list"'::jsonb),
  ('catalogue.export_sub',       '"A plain product list — no prices."'::jsonb),
  ('catalogue.export_action',    '"Make the PDF"'::jsonb),
  ('catalogue.export_building',  '"Preparing your list…"'::jsonb),
  ('catalogue.export_ready',     '"Your list is ready"'::jsonb),
  ('catalogue.export_empty',     '"There is nothing in this list to print."'::jsonb),
  ('catalogue.export_share',     '"Share on WhatsApp"'::jsonb),
  ('catalogue.export_col_name',  '"Product"'::jsonb),
  ('catalogue.export_col_company','"Company"'::jsonb),
  ('catalogue.export_col_pack',  '"Pack"'::jsonb),
  ('catalogue.export_col_rx',    '"Rx"'::jsonb),
  ('catalogue.export_note',      '"Prices are not shown on this list."'::jsonb),
  ('catalogue.export_footer',    '"Generated from the mediBO catalogue."'::jsonb),
  ('catalogue.export_meta_count','"Products"'::jsonb),
  ('catalogue.export_meta_date', '"Date"'::jsonb)
on conflict (key) do nothing;

-- ── 3. Recently added ──────────────────────────────────────────────────────
-- Grouped by company, because a flat list of everything added in a month is a
-- wall; a buyer thinks "what's new from Cipla". The window is config, the
-- counts and every sentence are built here.
create or replace function public.catalogue_recent(
  p_days integer default null, p_offset integer default 0, p_limit integer default 20)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_days int; v_from timestamptz; v_lim int := least(greatest(coalesce(p_limit,20),1),60);
        v_rows jsonb; v_total int; v_companies int;
begin
  select coalesce(new_days,30) into v_days from public.catalogue_extras_config where id = 1;
  v_days := coalesce(p_days, v_days, 30);
  v_from := now() - make_interval(days => v_days);

  select count(*), count(distinct coalesce(nullif(btrim(marketer),''),'—'))
    into v_total, v_companies
    from public."MEDICINE"
   where created_at is not null and created_at >= v_from;

  select coalesce(jsonb_agg(jsonb_build_object(
           'company',      g.company,
           'count_label',  format(public.uic('catalogue.recent_count','%s product(s)'), g.n),
           'count',        g.n,
           'items',        public._cat_cards(g.ids)) order by g.n desc, g.company), '[]'::jsonb)
    into v_rows
    from (select coalesce(nullif(btrim(m.marketer),''),'—') as company,
                 count(*) as n,
                 (array_agg(m.id order by m.created_at desc))[1:12] as ids
            from public."MEDICINE" m
           where m.created_at is not null and m.created_at >= v_from
           group by 1
           order by count(*) desc, 1
           limit v_lim offset greatest(coalesce(p_offset,0),0)) g;

  return jsonb_build_object(
    'ok', true,
    'title',      public.uic('catalogue.recent_title','Recently added'),
    'subtitle',   format(public.uic('catalogue.recent_sub','Products added in the last %s days'), v_days),
    'empty_text', public.uic('catalogue.recent_empty','Nothing new in this window yet.'),
    'days',       v_days,
    'count',      v_total,
    'has_more',   (greatest(coalesce(p_offset,0),0) + v_lim) < v_companies,
    'groups',     v_rows);
end $$;

-- The badge every list already draws. Added to _cat_cards so a "New" chip shows
-- wherever a catalogue card shows, rather than only on the Recently-added page.
create or replace function public._cat_cards(p_ids bigint[])
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', m.id,
    'name', m.product_name,
    'company', m.marketer,
    'pack_label', public.sf_pack_badge(m.pack_qty, m.pack_size, m.pack_type),
    'form_chip', coalesce(nullif(btrim(m.pack_type),''), nullif(btrim(m.pack_size),'')),
    'pack_qty_label',  public.sf_pack_qty_label(m.pack_qty),
    'pack_type_label', public.sf_pack_type_label(m.pack_type),
    'image', m.image_url_1,
    'category', m.therapeutic_class,
    'salt', m.salt_composition,
    'has_offer', coalesce(m.has_scheme, false),
    'offer_chip', case when coalesce(m.has_scheme, false)
                       then public.uic('catalogue.scheme_chip','Scheme available') else '' end,
    -- CHANGE #748 — the "New" chip. A card is new because the BACKEND says so
    -- against its own window, never because Dart compared a date: is_new and
    -- the label travel together and an absent created_at is simply not new.
    'is_new', (m.created_at is not null
               and m.created_at >= now() - make_interval(days =>
                     coalesce((select new_days from public.catalogue_extras_config where id = 1), 30))),
    'new_badge', case when (m.created_at is not null
               and m.created_at >= now() - make_interval(days =>
                     coalesce((select new_days from public.catalogue_extras_config where id = 1), 30)))
                 then public.uic('catalogue.new_badge','New') else '' end,
    'rx', public.rx_badge(m.rx_required),
    'availability', public.storefront_cta(
        public.storefront_effective_count(m.id,
          coalesce(nullif(regexp_replace(coalesce(m.supplier_count::text,''),'[^0-9]','','g'),'')::int, 0)),
        true, m.status),
    'pricing', public.storefront_pricing(
        nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric, null::numeric, m.id),
    'mrp_label', case when nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'') is not null
                 then '₹'||to_char(nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric,'FM999999990.00') end,
    'buyable', lower(coalesce(m.buyable::text,'')) in ('true','t')
  ) order by o.ord), '[]'::jsonb)
  from unnest(p_ids) with ordinality o(pid, ord)
  join "MEDICINE" m on m.id = o.pid;
$$;

-- ── 4. "Missing product?" — the request, and its duplicate guard ────────────
-- The pending-medicine table was supplier-only (submit_pending_medicine raises
-- 'not_supplier'). A CUSTOMER asking for a product is the same queue and the
-- same approval, so the table learns who asked and what else they could tell
-- us, rather than growing a second queue an admin has to remember to look at.
alter table public.supplier_pending_medicines
  add column if not exists requester_kind text not null default 'supplier',
  add column if not exists customer_id    uuid,
  add column if not exists requested_by   text not null default '',
  add column if not exists phone10        text not null default '',
  add column if not exists salt           text not null default '',
  add column if not exists pack           text not null default '',
  add column if not exists photo_path     text not null default '',
  add column if not exists notified_at    timestamptz,
  add column if not exists approved_product_id bigint;

-- supplier_id was NOT NULL because the queue only ever had one kind of asker.
-- A customer request has no supplier, and inventing one (or a sentinel row)
-- would corrupt every supplier-scoped read of this table. Relaxing the
-- constraint loses no data and changes no existing row; requester_kind is what
-- now says who asked.
alter table public.supplier_pending_medicines
  alter column supplier_id drop not null;

create index if not exists spm_customer_idx
  on public.supplier_pending_medicines (customer_id, created_at desc)
  where customer_id is not null;

-- The duplicate check the form runs BEFORE it submits. Trigram-free on purpose:
-- an exact-ish name match plus the company is what a buyer means by "you
-- already have this", and a fuzzy match on a 563k-row table is the
-- scalar-helper-scan trap. Bounded by the name index.
create or replace function public.catalogue_request_check(
  p_name text, p_company text default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_name text := lower(btrim(coalesce(p_name,''))); v_hit jsonb;
begin
  if v_name = '' then
    return jsonb_build_object('ok', false, 'error','need_name',
      'message', public.uic('catalogue.request_need_name','Please enter the product name.'));
  end if;
  select jsonb_build_object('id', m.id, 'name', m.product_name, 'company', m.marketer)
    into v_hit
    from public."MEDICINE" m
   where lower(btrim(m.product_name)) = v_name
      or lower(btrim(m.product_name)) like v_name || ' %'
   order by (lower(btrim(m.product_name)) = v_name) desc, m.id
   limit 1;

  if v_hit is null then
    return jsonb_build_object('ok', true, 'duplicate', false);
  end if;
  return jsonb_build_object('ok', true, 'duplicate', true, 'product', v_hit,
    'message', public.uic('catalogue.request_dupe','We already have this — here it is.'),
    'cta',     public.uic('catalogue.request_dupe_cta','Open it'));
end $$;

create or replace function public.catalogue_request_product(
  p_name text, p_company text default null, p_salt text default null,
  p_pack text default null, p_photo_path text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_open boolean; v_dupe jsonb; v_id bigint; v_cust uuid := public.my_customer_id();
begin
  select coalesce(request_open,true) into v_open from public.catalogue_extras_config where id = 1;
  if not coalesce(v_open,true) then
    return jsonb_build_object('ok', false, 'error','closed',
      'message', public.uic('catalogue.request_closed','Requests are paused right now.'));
  end if;
  if btrim(coalesce(p_name,'')) = '' then
    return jsonb_build_object('ok', false, 'error','need_name',
      'message', public.uic('catalogue.request_need_name','Please enter the product name.'));
  end if;

  -- The same guard the form ran, enforced on the WRITE: a form can be stale, or
  -- skipped entirely by a second tap, and a duplicate request is work for an
  -- admin that the catalogue could have answered.
  v_dupe := public.catalogue_request_check(p_name, p_company);
  if coalesce((v_dupe->>'duplicate')::boolean,false) then
    return v_dupe || jsonb_build_object('ok', false, 'error','duplicate');
  end if;

  insert into public.supplier_pending_medicines
    (supplier_id, product_name, marketer, status, requester_kind, customer_id,
     requested_by, phone10, salt, pack, photo_path)
  values (null, btrim(p_name), nullif(btrim(coalesce(p_company,'')),''), 'pending',
          case when v_cust is null then 'staff' else 'customer' end, v_cust,
          coalesce(auth.jwt() ->> 'email',''), coalesce(public.my_phone10(),''),
          btrim(coalesce(p_salt,'')), btrim(coalesce(p_pack,'')),
          btrim(coalesce(p_photo_path,'')))
  returning id into v_id;

  return jsonb_build_object('ok', true, 'request_id', v_id,
    'message', public.uic('catalogue.request_sent',
                          'Thanks — we will add it and let you know.'));
end $$;

-- What the requester sees afterwards. Their own rows only; the status WORD and
-- its tone are the backend's, so "Being checked" can be re-worded without a
-- deploy.
create or replace function public.catalogue_my_requests(p_limit integer default 20)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_cust uuid := public.my_customer_id(); v_rows jsonb;
begin
  if v_cust is null then
    return jsonb_build_object('ok', true, 'title',
      public.uic('catalogue.request_mine','Your requests'), 'rows', '[]'::jsonb);
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'request_id', r.id,
           'name',       r.product_name,
           'sub',        btrim(concat_ws(' · ', nullif(r.marketer,''), nullif(r.pack,''))),
           'date_label', to_char(r.created_at at time zone 'Asia/Kolkata','DD Mon YYYY'),
           'status_label', case r.status
                             when 'approved' then public.uic('catalogue.request_approved','Added to the catalogue')
                             when 'rejected' then public.uic('catalogue.request_rejected','Not added')
                             else public.uic('catalogue.request_pending','Being checked') end,
           'status_tone',  case r.status when 'approved' then 'success'
                                         when 'rejected' then 'danger' else 'warning' end,
           'product_id',   r.approved_product_id)
         order by r.created_at desc), '[]'::jsonb)
    into v_rows
    from (select * from public.supplier_pending_medicines
           where customer_id = v_cust
           order by created_at desc
           limit least(greatest(coalesce(p_limit,20),1),100)) r;
  return jsonb_build_object('ok', true,
    'title', public.uic('catalogue.request_mine','Your requests'), 'rows', v_rows);
end $$;

-- ── 5. Approval closes the loop ────────────────────────────────────────────
-- The approve function inserted a MEDICINE row and marked the pending row, and
-- told nobody. A customer who asked for a product and never heard back asks
-- again, or stops asking. Re-declared in full so the path stays one readable
-- function: it now stamps created_at (which is what makes the product show up
-- under Recently added), records WHICH product it became, and notifies the
-- requester. The notify is wrapped: a WhatsApp failure must never roll back an
-- approval.
create or replace function public.admin_approve_pending_medicine(
  p_id bigint, p_name text, p_marketer text, p_therapeutic_class text, p_mrp text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_role text := coalesce(public.get_my_role(),'none');
        v_exists boolean; v_added boolean := false; v_pid bigint;
        r public.supplier_pending_medicines%rowtype;
begin
  if v_role not in ('admin','super_admin') then raise exception 'forbidden'; end if;

  select id into v_pid from public."MEDICINE"
   where lower(btrim(product_name)) = lower(btrim(coalesce(p_name,''))) limit 1;
  v_exists := v_pid is not null;

  if not v_exists then
    -- data_source is NOT NULL and this insert never set it, so approving a
    -- product that was not already in the catalogue raised
    -- "null value in column data_source" and the approval failed - the whole
    -- point of the queue. Every one of the 562,549 existing rows says '1mg'
    -- (the original scrape); a product somebody ASKED for did not come from
    -- there, and saying so is what lets the two be told apart later.
    insert into public."MEDICINE" (product_name, marketer, therapeutic_class, mrp,
                                   data_source, created_at)
    values (btrim(p_name), nullif(btrim(coalesce(p_marketer,'')),''),
            nullif(btrim(coalesce(p_therapeutic_class,'')),''),
            nullif(btrim(coalesce(p_mrp,'')),''), 'request', now())
    returning id into v_pid;
    v_added := true;
  end if;

  update public.supplier_pending_medicines
     set status = 'approved', approved_product_id = v_pid
   where id = p_id
  returning * into r;

  -- CHANGE #748 — tell the person who asked.
  if r.id is not null and coalesce(btrim(r.phone10),'') <> '' and r.notified_at is null then
    begin
      perform public.notify('catalogue_request_approved', r.phone10, jsonb_build_object(
        'product_name', btrim(coalesce(p_name,'')),
        'product_link', 'https://medibo.in/product/' || v_pid::text));
      update public.supplier_pending_medicines set notified_at = now() where id = r.id;
    exception when others then null;
    end;
  end if;

  return jsonb_build_object('ok',true,'catalogue_row_added',v_added,'product_id',v_pid);
end $$;

insert into public.wa_event_routes
  (event_key, label, description, language, variable_map, enabled, auto_manage,
   auto_template_name, bypass_send_window, audience, wa_category, marketing_guard,
   dedupe_minutes, push_enabled, email_enabled, email_mode,
   push_title, push_body, email_subject, email_body)
values
  ('catalogue_request_approved',
   'A requested product was added to the catalogue',
   'CHANGE #748 — somebody asked for a product we did not stock; this tells them it is searchable now.',
   'en',
   '["{{product_name}}", "{{product_link}}"]'::jsonb,
   true, true, 'catalogue_request_approved', true, 'customer', 'utility', true, 0,
   true, true, 'fallback',
   '{{product_name}} is now on mediBO',
   'The product you asked for has been added. Tap to see it.',
   '{{product_name}} has been added to the catalogue',
   'The product you asked for is now on mediBO: {{product_link}}')
on conflict (event_key) do update
  set label = excluded.label, description = excluded.description,
      variable_map = excluded.variable_map, audience = excluded.audience,
      auto_manage = true, auto_template_name = excluded.auto_template_name,
      push_enabled = true, email_enabled = true, email_mode = excluded.email_mode,
      push_title = excluded.push_title, push_body = excluded.push_body,
      email_subject = excluded.email_subject, email_body = excluded.email_body,
      updated_at = now();

-- ── 6. Export — the list, with the money deliberately absent ───────────────
-- A buyer wants to hand a supplier or a colleague "the products I stock", and
-- MRP/PTR/margin must not travel with it. So the export is built from its OWN
-- column list and never from the card payload: a card carries pricing, and
-- filtering it out in Dart would be one refactor away from leaking it. The
-- columns here are name, company, pack and the Rx flag - there is no price
-- column to forget to remove.
create table if not exists public.catalogue_export (
  id          uuid primary key default gen_random_uuid(),
  customer_id uuid,
  requested_by text not null default '',
  kind        text not null default 'list',
  title       text not null default '',
  product_ids bigint[] not null default '{}',
  row_count   integer not null default 0,
  pdf_bucket  text,
  pdf_path    text,
  pdf_name    text,
  pdf_status  text not null default 'idle',
  pdf_error   text,
  pdf_bytes   integer,
  created_at  timestamptz not null default now()
);
-- `create table if not exists` is a no-op on an existing table, so a column
-- added after the first release must be declared separately or a resumed
-- worker's re-run silently skips it.
alter table public.catalogue_export
  add column if not exists customer_id uuid;

alter table public.catalogue_export enable row level security;

create or replace function public.catalogue_export_start(
  p_product_ids bigint[] default null, p_title text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_max int; v_ids bigint[]; v_id uuid; v_n int;
begin
  select coalesce(export_max,500) into v_max from public.catalogue_extras_config where id = 1;
  -- The ids are the list the caller is LOOKING at. Clamped, and reduced to ones
  -- that really exist, so a stale screen cannot ask for a page of blanks.
  select coalesce(array_agg(t.id), '{}') into v_ids from (
    select m.id from public."MEDICINE" m
     where m.id = any (coalesce(p_product_ids, '{}'::bigint[]))
     order by m.product_name, m.id
     limit coalesce(v_max,500)) t;
  v_n := coalesce(array_length(v_ids,1), 0);
  if v_n = 0 then
    return jsonb_build_object('ok', false, 'error','empty',
      'message', public.uic('catalogue.export_empty','There is nothing in this list to print.'));
  end if;

  insert into public.catalogue_export (customer_id, requested_by, title, product_ids, row_count)
  values (public.my_customer_id(), coalesce(auth.jwt() ->> 'email',''),
          btrim(coalesce(nullif(p_title,''), public.uic('catalogue.export_title','My catalogue list'))),
          v_ids, v_n)
  returning id into v_id;

  perform net.http_post(
    url     := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/px-invoice',
    headers := jsonb_build_object('Content-Type','application/json',
                                  'x-notify-secret','medibo_order_notify_2027',
                                  'Authorization','Bearer ' || public._service_key()),
    body    := jsonb_build_object('source','catalogue_export','export_id', v_id),
    timeout_milliseconds := 25000);

  return jsonb_build_object('ok', true, 'status','building', 'export_id', v_id,
    'count', v_n, 'poll_ms', 1500,
    'message', public.uic('catalogue.export_building','Preparing your list…'));
end $$;

create or replace function public.catalogue_export_status(p_export_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare e public.catalogue_export%rowtype;
begin
  select * into e from public.catalogue_export where id = p_export_id;
  if not found then
    return jsonb_build_object('ok', false, 'error','not_found',
      'message', public.uic('catalogue.export_empty','There is nothing in this list to print.'));
  end if;
  if e.pdf_status = 'ready' and coalesce(e.pdf_path,'') <> '' then
    return jsonb_build_object('ok', true, 'status','ready', 'export_id', e.id,
      'bucket', e.pdf_bucket, 'path', e.pdf_path, 'file_name', e.pdf_name,
      'expires_s', 300, 'share_label', public.uic('catalogue.export_share','Share on WhatsApp'),
      'message', public.uic('catalogue.export_ready','Your list is ready'));
  end if;
  if e.pdf_status = 'error' then
    return jsonb_build_object('ok', false, 'error','render_failed',
      'message', public.uic('catalogue.export_empty','There is nothing in this list to print.'));
  end if;
  return jsonb_build_object('ok', true, 'status','building', 'export_id', e.id,
    'poll_ms', 1500, 'message', public.uic('catalogue.export_building','Preparing your list…'));
end $$;

-- The SAME payload shape the shared renderer draws (#420 / #695). No 'pricing'
-- key exists in it at all - that is the point.
create or replace function public.catalogue_export_render_input(p_export_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare e public.catalogue_export%rowtype; v_lines jsonb;
begin
  select * into e from public.catalogue_export where id = p_export_id;
  if not found then return jsonb_build_object('ok', false, 'error','not_found'); end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'desc',    m.product_name,
           'company', coalesce(nullif(btrim(m.marketer),''),'—'),
           'pack',    coalesce(nullif(public.sf_pack_badge(m.pack_qty, m.pack_size, m.pack_type),''),'—'),
           'rxflag',  case when lower(coalesce(m.rx_required::text,'')) in ('true','t','yes') then 'Rx' else '' end)
         order by m.product_name, m.id), '[]'::jsonb)
    into v_lines
    from public."MEDICINE" m
   where m.id = any (e.product_ids);

  return jsonb_build_object(
    'ok', true,
    'bucket', 'customer-bills',
    'path', 'catalogue/' || e.id::text || '.pdf',
    'file_name', 'catalogue-list-' || to_char(e.created_at at time zone 'Asia/Kolkata','YYYY-MM-DD') || '.pdf',
    'invoice', jsonb_build_object(
      'title', e.title,
      'seller', jsonb_build_object('heading','','name','','address',null,'phone',null,
                                   'gstin_label',null,'dl_label',null),
      'buyer',  jsonb_build_object('heading','','name','','address',null,'phone',null,
                                   'gstin_label',null,'dl_label',null),
      -- Its own two labels. These were the COLUMN keys at first, so the header
      -- read "Product 12" and "Pack 04 Sep 2026" - the right values under the
      -- wrong words, which is the sort of thing only a look at the drawn page
      -- catches.
      'meta', jsonb_build_array(
        jsonb_build_object('label', public.uic('catalogue.export_meta_count','Products'),
                           'value', e.row_count::text),
        jsonb_build_object('label', public.uic('catalogue.export_meta_date','Date'),
          'value', to_char(e.created_at at time zone 'Asia/Kolkata','DD Mon YYYY'))),
      'columns', jsonb_build_array(
        jsonb_build_object('key','desc',    'label', public.uic('catalogue.export_col_name','Product')),
        jsonb_build_object('key','company', 'label', public.uic('catalogue.export_col_company','Company')),
        jsonb_build_object('key','pack',    'label', public.uic('catalogue.export_col_pack','Pack')),
        jsonb_build_object('key','rxflag',  'label', public.uic('catalogue.export_col_rx','Rx'))),
      'lines', v_lines,
      'totals', '[]'::jsonb,
      'net', jsonb_build_object('label','', 'value',''),
      'disclosure', public.uic('catalogue.export_note','Prices are not shown on this list.'),
      'footer', jsonb_build_object(
        'note',  public.uic('catalogue.export_footer','Generated from the mediBO catalogue.'),
        'items', '')));
end $$;

create or replace function public.catalogue_export_report(
  p_export_id uuid, p_ok boolean, p_bucket text default null, p_path text default null,
  p_name text default null, p_bytes integer default null, p_error text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  update public.catalogue_export
     set pdf_status = case when p_ok then 'ready' else 'error' end,
         pdf_bucket = coalesce(p_bucket, pdf_bucket),
         pdf_path   = coalesce(p_path,   pdf_path),
         pdf_name   = coalesce(p_name,   pdf_name),
         pdf_bytes  = coalesce(p_bytes,  pdf_bytes),
         pdf_error  = case when p_ok then null else p_error end
   where id = p_export_id;
  return jsonb_build_object('ok', true);
end $$;

-- ── 7. Grants ──────────────────────────────────────────────────────────────
grant execute on function public.catalogue_recent(integer,integer,integer)          to anon, authenticated;
grant execute on function public.catalogue_request_check(text,text)                 to authenticated;
grant execute on function public.catalogue_request_product(text,text,text,text,text) to authenticated;
grant execute on function public.catalogue_my_requests(integer)                     to authenticated;
grant execute on function public.catalogue_export_start(bigint[],text)              to authenticated;
grant execute on function public.catalogue_export_status(uuid)                      to authenticated;
grant execute on function public.catalogue_export_render_input(uuid)                to service_role;
grant execute on function public.catalogue_export_report(uuid,boolean,text,text,text,integer,text) to service_role;

-- ── 8. Where the three live — all of it DATA on catalogue_home() ───────────
-- The tab strip is already a payload the screen renders in order, skipping any
-- `kind` it does not know. So "Recently added" is a new tab row plus one arm in
-- Dart, and the request form and the export are an `extras` block the screen
-- draws if it is there. Nothing about placement is hard-coded in Flutter.
create or replace function public.catalogue_extras(p_zone boolean default true)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare c public.catalogue_extras_config%rowtype; v_recent int;
begin
  select * into c from public.catalogue_extras_config where id = 1;
  select count(*) into v_recent from public."MEDICINE"
   where created_at is not null
     and created_at >= now() - make_interval(days => coalesce(c.new_days,30));

  return jsonb_build_object(
    'recent', jsonb_build_object(
      'key',   'recent',
      'kind',  'recent',
      'label', public.uic('catalogue.recent_title','Recently added'),
      'count', v_recent,
      'count_label', public.cat_count_label(v_recent::bigint),
      -- The tab is offered only when there IS something new. An empty tab that
      -- is always there teaches people to stop tapping it.
      'show',  v_recent > 0),
    'request', jsonb_build_object(
      'show',         coalesce(c.request_open,true),
      'title',        public.uic('catalogue.request_title','Missing product?'),
      'subtitle',     public.uic('catalogue.request_sub','Tell us what you could not find and we will add it.'),
      'submit_label', public.uic('catalogue.request_submit','Send request'),
      'fields', jsonb_build_array(
        jsonb_build_object('key','name',    'label', public.uic('catalogue.request_name','Product name'),    'required', true),
        jsonb_build_object('key','company', 'label', public.uic('catalogue.request_company','Company'),      'required', false),
        jsonb_build_object('key','salt',    'label', public.uic('catalogue.request_salt','Salt / composition'),'required', false),
        jsonb_build_object('key','pack',    'label', public.uic('catalogue.request_pack','Pack'),            'required', false)),
      'photo_label',  public.uic('catalogue.request_photo','Add a photo (optional)')),
    'export', jsonb_build_object(
      'show',         true,
      'title',        public.uic('catalogue.export_title','Print / share my catalogue list'),
      'subtitle',     public.uic('catalogue.export_sub','A plain product list — no prices.'),
      'action_label', public.uic('catalogue.export_action','Make the PDF'),
      'max',          coalesce(c.export_max,500)));
end $$;

grant execute on function public.catalogue_extras(boolean) to anon, authenticated;
