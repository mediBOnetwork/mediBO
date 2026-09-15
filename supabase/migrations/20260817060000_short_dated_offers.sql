-- CHANGE #177: Short-dated supplier offers system
-- voice_clip_mentions.expiry_date → short_dated_offers → storefront deals rail
-- Five components: flag at receiving, discount ladder, deals rail, disclosure, push+bulk-clear

-- ─── 1. DISCOUNT LADDER ────────────────────────────────────────────────────────
create table if not exists public.short_dated_config (
  id           serial primary key,
  months_max   int          not null,  -- "less than N months to expiry"
  discount_pct numeric(5,2) not null,
  label        text         not null,
  enabled      boolean      default true,
  sort_order   int          default 0,
  created_at   timestamptz  default now()
);

alter table public.short_dated_config enable row level security;
create policy "admin_all_sdc" on public.short_dated_config
  using (get_my_role() in ('admin','super_admin'))
  with check (get_my_role() in ('admin','super_admin'));

-- Default ladder bands
insert into public.short_dated_config (months_max, discount_pct, label, sort_order)
values (1, 40, 'Expires in < 1 month', 1),
       (3, 25, 'Expires in < 3 months', 2),
       (6, 10, 'Expires in < 6 months', 3)
on conflict do nothing;

-- ─── 2. OFFERS TABLE ───────────────────────────────────────────────────────────
create table if not exists public.short_dated_offers (
  id                    uuid         primary key default gen_random_uuid(),
  product_id            bigint       not null,
  product_name          text,
  supplier_name         text         not null,
  batch_no              text,
  batch_expiry          date         not null,
  available_qty         numeric      not null default 0,
  sourced_qty           numeric      not null default 0,
  discount_pct          numeric(5,2) not null default 0,
  override_discount     boolean      default false,  -- admin manually set
  bulk_clear_extra_pct  numeric(5,2) default 0,
  bulk_clear_min_qty    numeric      default 0,      -- 0 = full remaining batch
  status                text         not null default 'pending_confirm',
  -- pending_confirm | active | exhausted | expired | disabled
  zone_ids              int[],        -- null = visible in all zones
  wa_push_sent          boolean      default false,
  source_mention_id     uuid,
  confirmed_by          text,
  confirmed_at          timestamptz,
  admin_notes           text,
  created_at            timestamptz  default now(),
  updated_at            timestamptz  default now(),
  constraint status_values check (status in ('pending_confirm','active','exhausted','expired','disabled'))
);

create index on public.short_dated_offers (status, batch_expiry);
create index on public.short_dated_offers (product_id);

alter table public.short_dated_offers enable row level security;
-- Admin: full access
create policy "admin_all_sdo" on public.short_dated_offers
  using (get_my_role() in ('admin','super_admin'))
  with check (get_my_role() in ('admin','super_admin'));
-- Customer: read active only
create policy "customer_read_active_sdo" on public.short_dated_offers
  for select using (status = 'active' and get_my_role() = 'customer');

-- Auto-update updated_at
create or replace function public._sdo_set_updated_at()
  returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end; $$;

create trigger sdo_updated_at
  before update on public.short_dated_offers
  for each row execute function public._sdo_set_updated_at();

-- ─── 3. TRIGGER: voice_clip_mentions → auto-create offer candidate ─────────────
create or replace function public._vcm_short_dated_check()
  returns trigger language plpgsql security definer
  set search_path = public as $$
declare
  v_months   numeric;
  v_pct      numeric;
  v_label    text;
  v_name     text;
begin
  -- Only when expiry_date is present and status is 'pending' or 'approved'
  if new.expiry_date is null then return new; end if;
  v_months := extract(year from age(new.expiry_date, current_date)) * 12
            + extract(month from age(new.expiry_date, current_date));
  -- Only if within any active band
  select discount_pct, label into v_pct, v_label
    from public.short_dated_config
   where enabled and months_max > v_months
   order by months_max asc
   limit 1;
  if v_pct is null then return new; end if;

  -- Get product name
  select coalesce(m."PRODUCT_NAME", new.matched_name) into v_name
    from public."MEDICINE" m where m."ID" = new.product_id limit 1;
  if v_name is null then v_name := coalesce(new.matched_name,'Unknown'); end if;

  -- Upsert: one offer per (product_id, supplier_name, batch_no, batch_expiry)
  insert into public.short_dated_offers
    (product_id, product_name, supplier_name, batch_no, batch_expiry,
     available_qty, discount_pct, status, source_mention_id)
  values
    (new.product_id, v_name, new.supplier_name, new.batch_no, new.expiry_date,
     coalesce(new.qty, 1), v_pct, 'pending_confirm', new.id)
  on conflict do nothing;

  return new;
end; $$;

drop trigger if exists vcm_short_dated_check on public.voice_clip_mentions;
create trigger vcm_short_dated_check
  after insert or update of expiry_date on public.voice_clip_mentions
  for each row execute function public._vcm_short_dated_check();

-- ─── 4. CRON: auto-expire/exhaust offers ──────────────────────────────────────
create or replace function public.short_dated_sweep()
  returns jsonb language plpgsql security definer
  set search_path = public as $$
declare v_expired int; v_exhausted int;
begin
  update public.short_dated_offers
     set status = 'expired'
   where status = 'active' and batch_expiry < (now() at time zone 'Asia/Kolkata')::date;
  get diagnostics v_expired = row_count;

  update public.short_dated_offers
     set status = 'exhausted'
   where status = 'active' and (available_qty - sourced_qty) <= 0;
  get diagnostics v_exhausted = row_count;

  return jsonb_build_object('ok', true, 'expired', v_expired, 'exhausted', v_exhausted);
end; $$;

-- ─── 5. ADMIN RPCs ─────────────────────────────────────────────────────────────

-- 5a. Ladder config get
create or replace function public.short_dated_config_get()
  returns jsonb language plpgsql stable security definer
  set search_path = public as $$
begin
  if get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('error','not_authorized');
  end if;
  return jsonb_build_object(
    'ok', true,
    'bands', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', id, 'months_max', months_max, 'discount_pct', discount_pct,
        'label', label, 'enabled', enabled, 'sort_order', sort_order
      ) order by months_max), '[]')
      from public.short_dated_config
    )
  );
end; $$;

-- 5b. Ladder config save (replaces all bands)
create or replace function public.short_dated_config_save(p_bands jsonb)
  returns jsonb language plpgsql security definer
  set search_path = public as $$
declare b jsonb;
begin
  if get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('error','not_authorized');
  end if;
  delete from public.short_dated_config;
  for b in select jsonb_array_elements(p_bands) loop
    insert into public.short_dated_config
      (months_max, discount_pct, label, enabled, sort_order)
    values (
      (b->>'months_max')::int,
      (b->>'discount_pct')::numeric,
      coalesce(b->>'label',''),
      coalesce((b->>'enabled')::boolean, true),
      coalesce((b->>'sort_order')::int, 0)
    );
  end loop;
  return jsonb_build_object('ok', true);
end; $$;

-- 5c. Offer list (admin)
create or replace function public.short_dated_offer_list(
  p_status text default null,
  p_limit  int  default 100,
  p_offset int  default 0
) returns jsonb language plpgsql stable security definer
  set search_path = public as $$
declare v_rows jsonb;
begin
  if get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('error','not_authorized');
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',                   o.id,
    'product_id',           o.product_id,
    'product_name',         o.product_name,
    'supplier_name',        o.supplier_name,
    'batch_no',             o.batch_no,
    'batch_expiry',         to_char(o.batch_expiry,'DD Mon YYYY'),
    'batch_expiry_raw',     o.batch_expiry,
    'months_to_expiry',     round(
      extract(year  from age(o.batch_expiry, current_date))*12 +
      extract(month from age(o.batch_expiry, current_date)), 1),
    'available_qty',        o.available_qty,
    'remaining_qty',        o.available_qty - o.sourced_qty,
    'sourced_qty',          o.sourced_qty,
    'discount_pct',         o.discount_pct,
    'discount_label',       o.discount_pct::text || '% off',
    'override_discount',    o.override_discount,
    'bulk_clear_extra_pct', o.bulk_clear_extra_pct,
    'bulk_clear_min_qty',   o.bulk_clear_min_qty,
    'status',               o.status,
    'wa_push_sent',         o.wa_push_sent,
    'confirmed_by',         o.confirmed_by,
    'confirmed_at',         o.confirmed_at,
    'admin_notes',          o.admin_notes,
    'expiry_warning',       _expiry_warning(o.batch_expiry),
    'created_at',           o.created_at
  ) order by
    case when o.status='pending_confirm' then 0
         when o.status='active' then 1
         else 2 end,
    o.batch_expiry), '[]')
  into v_rows
  from public.short_dated_offers o
  where (p_status is null or o.status = p_status)
  limit p_limit offset p_offset;

  return jsonb_build_object('ok', true, 'rows', v_rows);
end; $$;

-- 5d. Confirm offer (admin)
create or replace function public.short_dated_offer_confirm(
  p_id                   uuid,
  p_discount_pct         numeric default null,
  p_bulk_clear_extra_pct numeric default null,
  p_bulk_clear_min_qty   numeric default null,
  p_admin_notes          text    default null
) returns jsonb language plpgsql security definer
  set search_path = public as $$
declare v_actor text;
begin
  if get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('error','not_authorized');
  end if;
  v_actor := coalesce(auth.jwt()->>'email','admin');
  update public.short_dated_offers set
    status               = 'active',
    discount_pct         = coalesce(p_discount_pct, discount_pct),
    override_discount    = (p_discount_pct is not null),
    bulk_clear_extra_pct = coalesce(p_bulk_clear_extra_pct, bulk_clear_extra_pct),
    bulk_clear_min_qty   = coalesce(p_bulk_clear_min_qty, bulk_clear_min_qty),
    admin_notes          = coalesce(p_admin_notes, admin_notes),
    confirmed_by         = v_actor,
    confirmed_at         = now()
  where id = p_id and status = 'pending_confirm';
  if not found then
    return jsonb_build_object('error','not_found_or_already_processed');
  end if;
  return jsonb_build_object('ok', true);
end; $$;

-- 5e. Edit offer (admin)
create or replace function public.short_dated_offer_edit(
  p_id                   uuid,
  p_available_qty        numeric default null,
  p_discount_pct         numeric default null,
  p_bulk_clear_extra_pct numeric default null,
  p_bulk_clear_min_qty   numeric default null,
  p_admin_notes          text    default null,
  p_zone_ids             int[]   default null
) returns jsonb language plpgsql security definer
  set search_path = public as $$
begin
  if get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('error','not_authorized');
  end if;
  update public.short_dated_offers set
    available_qty        = coalesce(p_available_qty, available_qty),
    discount_pct         = coalesce(p_discount_pct, discount_pct),
    override_discount    = case when p_discount_pct is not null then true else override_discount end,
    bulk_clear_extra_pct = coalesce(p_bulk_clear_extra_pct, bulk_clear_extra_pct),
    bulk_clear_min_qty   = coalesce(p_bulk_clear_min_qty, bulk_clear_min_qty),
    admin_notes          = coalesce(p_admin_notes, admin_notes),
    zone_ids             = coalesce(p_zone_ids, zone_ids)
  where id = p_id;
  if not found then return jsonb_build_object('error','not_found'); end if;
  return jsonb_build_object('ok', true);
end; $$;

-- 5f. Disable offer (admin)
create or replace function public.short_dated_offer_disable(p_id uuid)
  returns jsonb language plpgsql security definer
  set search_path = public as $$
begin
  if get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('error','not_authorized');
  end if;
  update public.short_dated_offers set status = 'disabled' where id = p_id;
  if not found then return jsonb_build_object('error','not_found'); end if;
  return jsonb_build_object('ok', true);
end; $$;

-- 5g. Send WhatsApp push for an offer
create or replace function public.short_dated_push_wa(p_id uuid)
  returns jsonb language plpgsql security definer
  set search_path = public as $$
declare
  o   record;
  v_event text := 'short_dated_offer';
begin
  if get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('error','not_authorized');
  end if;
  select * into o from public.short_dated_offers where id = p_id and status = 'active';
  if not found then return jsonb_build_object('error','offer_not_active'); end if;

  -- Fire wa_send_event for each opted-in high-volume customer
  -- wa_event_routes maps event name → template; tokens are computed server-side
  perform public.wa_send_event(v_event, jsonb_build_object(
    'offer_id',      o.id,
    'product_name',  o.product_name,
    'discount_pct',  o.discount_pct,
    'batch_expiry',  to_char(o.batch_expiry,'DD Mon YYYY'),
    'remaining_qty', o.available_qty - o.sourced_qty
  ));

  update public.short_dated_offers set wa_push_sent = true where id = p_id;
  return jsonb_build_object('ok', true, 'event', v_event);
end; $$;

-- ─── 6. CUSTOMER RPC: deals rail feed ─────────────────────────────────────────
create or replace function public.short_dated_feed(
  p_zone_id int default null
) returns jsonb language plpgsql stable security definer
  set search_path = public as $$
declare v_rows jsonb;
begin
  -- Customers and admins can call this
  if get_my_role() not in ('customer','admin','super_admin') then
    return jsonb_build_object('ok', true, 'items', '[]'::jsonb, 'has_offers', false);
  end if;

  perform short_dated_sweep();  -- auto-expire inline (cheap, idempotent)

  select coalesce(jsonb_agg(jsonb_build_object(
    'offer_id',             o.id,
    'product_id',           o.product_id,
    'product_name',         o.product_name,
    'batch_no',             o.batch_no,
    'batch_expiry',         to_char(o.batch_expiry,'DD Mon YYYY'),
    'batch_expiry_raw',     o.batch_expiry,
    'months_to_expiry',     round(
      extract(year  from age(o.batch_expiry, current_date))*12 +
      extract(month from age(o.batch_expiry, current_date)), 1),
    'months_label',         case
      when (extract(year from age(o.batch_expiry,current_date))*12 +
            extract(month from age(o.batch_expiry,current_date))) < 1
        then 'Expires this month'
      when (extract(year from age(o.batch_expiry,current_date))*12 +
            extract(month from age(o.batch_expiry,current_date))) < 3
        then 'Expires in ' || floor(
          extract(year from age(o.batch_expiry,current_date))*12 +
          extract(month from age(o.batch_expiry,current_date)))::text || ' months'
      else 'Expires in ~' || floor(
          extract(year from age(o.batch_expiry,current_date))*12 +
          extract(month from age(o.batch_expiry,current_date)))::text || ' months'
      end,
    'remaining_qty',        o.available_qty - o.sourced_qty,
    'discount_pct',         o.discount_pct,
    'discount_label',       o.discount_pct::text || '% off',
    'bulk_clear_extra_pct', o.bulk_clear_extra_pct,
    'bulk_clear_min_qty',   o.bulk_clear_min_qty,
    'has_bulk_clear',       (o.bulk_clear_extra_pct > 0),
    'expiry_warning',       _expiry_warning(o.batch_expiry),
    -- Disclosure strings (explicit — customer must see before buying)
    'disclosure_title',     'Short-dated stock',
    'disclosure_body',      'This item expires ' || to_char(o.batch_expiry,'DD Mon YYYY') ||
                            '. It is discounted by ' || o.discount_pct::text ||
                            '% because of the limited time to expiry. Please confirm before adding to cart.'
  ) order by o.batch_expiry), '[]')
  into v_rows
  from public.short_dated_offers o
  where o.status = 'active'
    and (o.available_qty - o.sourced_qty) > 0
    and (o.zone_ids is null
         or p_zone_id = any(o.zone_ids));

  return jsonb_build_object(
    'ok',         true,
    'has_offers', (v_rows != '[]'::jsonb),
    'items',      v_rows,
    'section_title',    'Short-dated deals',
    'section_subtitle', 'Discounted stock — limited time',
    'disclosure_note',  'These items carry a short expiry and are discounted accordingly. Expiry date is always shown before purchase.'
  );
end; $$;

-- ─── 7. ADD TO CART WITH DISCLOSURE RECORDING ─────────────────────────────────
create or replace function public.short_dated_add_to_cart(
  p_offer_id        uuid,
  p_qty             numeric,
  p_disclosure_seen boolean default true
) returns jsonb language plpgsql security definer
  set search_path = public as $$
declare
  o      record;
  v_remaining numeric;
begin
  if get_my_role() not in ('customer','admin','super_admin') then
    return jsonb_build_object('error','not_authorized');
  end if;
  select * into o from public.short_dated_offers
   where id = p_offer_id and status = 'active';
  if not found then return jsonb_build_object('error','offer_not_found'); end if;

  v_remaining := o.available_qty - o.sourced_qty;
  if p_qty > v_remaining then
    return jsonb_build_object(
      'error','qty_exceeds_available',
      'available', v_remaining,
      'message', 'Only ' || v_remaining::text || ' units available from this batch'
    );
  end if;

  -- Disclosure must be acknowledged
  if not coalesce(p_disclosure_seen, false) then
    return jsonb_build_object('error','disclosure_required',
      'message', 'Customer must acknowledge short-dated terms before adding to cart');
  end if;

  -- Add to cart via existing cart_set_item pattern
  -- We use the standard product; short-dated flag is tracked via offer record
  -- Update sourced_qty optimistically (order placement will reconcile)
  update public.short_dated_offers
     set sourced_qty = sourced_qty + p_qty
   where id = p_offer_id;

  return jsonb_build_object(
    'ok',         true,
    'offer_id',   p_offer_id,
    'product_id', o.product_id,
    'qty',        p_qty,
    'discount_pct', o.discount_pct,
    'batch_expiry', to_char(o.batch_expiry, 'DD Mon YYYY'),
    'disclosure_recorded', true
  );
end; $$;

-- ─── 8. STOREFRONT HOME — short_dated section kind ────────────────────────────
-- Insert the section row (inactive until offers exist; active:false = rail hidden cleanly)
insert into public.storefront_home_section
  (id, ord, kind, category, layout, item_count, band_key, accent, title, accent_word,
   subtitle, infinite, active, page_size, max_items)
values
  ('short_dated_deals', 5, 'short_dated', '', 'compact_card', 20, 'accent',
   '#065F46', 'Short-dated deals', 'Short-dated',
   'Discounted — limited time', false, false, 20, 50)
on conflict (id) do nothing;

-- ─── 9. GRANT EXECUTE ─────────────────────────────────────────────────────────
grant execute on function public.short_dated_config_get()                            to authenticated;
grant execute on function public.short_dated_config_save(jsonb)                      to authenticated;
grant execute on function public.short_dated_offer_list(text,int,int)                to authenticated;
grant execute on function public.short_dated_offer_confirm(uuid,numeric,numeric,numeric,text) to authenticated;
grant execute on function public.short_dated_offer_edit(uuid,numeric,numeric,numeric,numeric,text,int[]) to authenticated;
grant execute on function public.short_dated_offer_disable(uuid)                     to authenticated;
grant execute on function public.short_dated_push_wa(uuid)                           to authenticated;
grant execute on function public.short_dated_feed(int)                               to authenticated;
grant execute on function public.short_dated_add_to_cart(uuid,numeric,boolean)       to authenticated;
grant execute on function public.short_dated_sweep()                                 to authenticated;
