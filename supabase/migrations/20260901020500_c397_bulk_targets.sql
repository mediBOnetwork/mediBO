-- CHANGE #397 — part 2: WHICH admin lists are bulk-editable.
--
-- Pure data. A new bulk-editable list is an INSERT here, never a deploy: the
-- screen reads this registry, renders the target picker from it, and the engine
-- validates against it.
--
-- Deliberately absent: anything that moves money. A refund, a payment claim, a
-- partner payout and a bill are reversed through their own accounting flows —
-- the generic engine must never touch them (see audit_table_config.undoable).

-- Labels for the entity types these batches record against. The row trigger is
-- NOT attached to these tables here: a per-row trigger on a 563k-row catalogue
-- would write an audit row for every import line. The batch writes its own
-- single entry instead, which is what the change asks for. The config rows
-- exist so the audit screen can name the entity and answer "is it undoable?".
insert into public.audit_table_config(table_name, entity_type, label, pk_col, skip_cols, is_active, undoable)
values ('MEDICINE',          'product',         'Product',         'id',         '{}', false, true),
       ('medicine_pricing',  'product_pricing', 'Product pricing', 'product_id', '{}', false, true),
       ('pharmacy_profiles', 'customer',        'Customer',        'id',         '{}', false, true),
       ('supplier_profiles', 'supplier',        'Supplier',        'id',         '{}', false, true)
on conflict (table_name) do update
   set label = excluded.label, entity_type = excluded.entity_type;

-- ── the lists ───────────────────────────────────────────────────────────────
insert into public.admin_bulk_target(
  key, label, hint, table_name, pk_col, entity_type, feature_key,
  name_expr, extra_expr, filter_sql, search_expr, extra_set,
  require_search, undoable, sort_order, is_active)
values
  ('product_availability',
   'Product availability',
   'Catalogue sale status and the GST rate a product bills at. The buyable flag is NOT here — it is derived from live supplier availability by a trigger and cannot be set by hand.',
   'MEDICINE', 'id', 'product', 'admin.pricing_backfill',
   't.product_name',
   $$coalesce(t.marketer,'') || ' · ' || coalesce(nullif(t.status,''),'No status') || case when t.buyable then ' · In stock' else '' end$$,
   'true', 't.product_name', '',
   true, true, 10, true),

  ('product_pricing',
   'Product pricing',
   'Trade rate (PTR), GST and the pricing-ready flag. MRP is never edited here — it is the printed ceiling, not the selling price.',
   'medicine_pricing', 'product_id', 'product_pricing', 'admin.pricing_backfill',
   $$coalesce((select m.product_name from public."MEDICINE" m where m.id = t.product_id), 'Product ' || t.product_id::text)$$,
   $$'PTR ' || coalesce(t.ptr::text,'—') || ' · GST ' || coalesce(t.gst_pct::text,'—') || '%'$$,
   'true',
   $$coalesce((select m.product_name from public."MEDICINE" m where m.id = t.product_id), '')$$,
   'pricing_updated_at = now()',
   false, true, 20, true),

  ('customer_records',
   'Customers',
   'Zone, approval and soft-delete for licensed pharmacies, clinics and hospitals.',
   'pharmacy_profiles', 'id', 'customer', 'admin.customers',
   $$coalesce(nullif(btrim(t.pharmacy_name),''), nullif(btrim(t.customer_name),''), nullif(btrim(t.owner_name),''), 'Customer')$$,
   $$coalesce(nullif(t.city,''),'') || case when t.zone_id is null then '' else ' · Zone ' || t.zone_id::text end$$,
   'coalesce(t.is_deleted, false) = false',
   $$coalesce(t.pharmacy_name,'') || ' ' || coalesce(t.customer_name,'') || ' ' || coalesce(t.phone,'')$$,
   '',
   false, true, 30, true),

  ('supplier_records',
   'Suppliers',
   'Zone, status and soft-delete for wholesale distributors.',
   'supplier_profiles', 'id', 'supplier', 'admin.suppliers',
   $$coalesce(nullif(btrim(t.supplier_name),''), nullif(btrim(t.contact_name),''), 'Supplier')$$,
   $$coalesce(nullif(t.city,''),'') || case when t.zone_id is null then '' else ' · Zone ' || t.zone_id::text end$$,
   'coalesce(t.is_deleted, false) = false',
   $$coalesce(t.supplier_name,'') || ' ' || coalesce(t.contact_name,'') || ' ' || coalesce(t.phone,'')$$,
   '',
   false, true, 40, true),

  ('order_status',
   'Order status',
   'Only orders that have not yet been packed, delivered, billed or cancelled — a shipped or billed order is never re-statused in bulk.',
   'orders', 'id', 'order', 'admin.order_closure',
   $$'Order ' || right(t.id::text, 8)$$,
   $$coalesce(t.status,'') || coalesce(' · ' || to_char(t.created_at at time zone 'Asia/Kolkata','DD Mon'), '')$$,
   $$lower(coalesce(t.status,'')) in ('pending','accepted','confirmed','processing')$$,
   $$t.id::text$$,
   '',
   false, true, 50, true)
on conflict (key) do update set
  label = excluded.label, hint = excluded.hint, table_name = excluded.table_name,
  pk_col = excluded.pk_col, entity_type = excluded.entity_type,
  feature_key = excluded.feature_key, name_expr = excluded.name_expr,
  extra_expr = excluded.extra_expr, filter_sql = excluded.filter_sql,
  search_expr = excluded.search_expr, extra_set = excluded.extra_set,
  require_search = excluded.require_search, undoable = excluded.undoable,
  sort_order = excluded.sort_order, is_active = excluded.is_active;

-- ── the fields ──────────────────────────────────────────────────────────────
insert into public.admin_bulk_field(
  target_key, field, label, input_kind, options, options_sql,
  min_value, max_value, hint, confirm_body, snapshot_cols, extra_set, sort_order)
values
  ('product_availability', 'status', 'Catalogue status', 'enum',
   '[{"value":"Available","label":"Available"},
     {"value":"SOLD OUT","label":"Sold out"},
     {"value":"NOT FOR SALE","label":"Not for sale"},
     {"value":"DISCONTINUED","label":"Discontinued"},
     {"value":"BANNED FOR SALE","label":"Banned for sale"}]'::jsonb,
   '', null, null,
   'The catalogue status a product is listed under. Whether it can actually be ordered also depends on live supplier availability.',
   'These products are listed under the new status straight away.',
   '{}', '', 10),

  ('product_availability', 'gst_percent', 'GST %', 'number',
   '[]'::jsonb, '', 0, 28,
   'The GST rate these products bill at. Wrong here means wrong on every future bill.',
   'Every future bill line for these products uses the new rate.',
   '{}', '', 20),

  ('product_pricing', 'ptr', 'Trade rate (PTR)', 'number',
   '[]'::jsonb, '', 0, 1000000,
   'The rate mediBO sells at, before discount and GST. Never the printed MRP.',
   'Every new order line for these products prices off the new trade rate.',
   '{pricing_updated_at}', '', 10),

  ('product_pricing', 'gst_pct', 'GST %', 'enum',
   '[{"value":"0","label":"0% — exempt"},{"value":"5","label":"5%"},{"value":"12","label":"12%"},{"value":"18","label":"18%"}]'::jsonb,
   '', null, null, 'The GST slab applied to these lines.',
   'Every future bill line for these products uses the new slab.',
   '{pricing_updated_at}', '', 20),

  ('product_pricing', 'pricing_ready', 'Pricing ready', 'bool',
   '[]'::jsonb, '', null, null,
   'Marks the trade price as checked and safe to sell on.',
   'Products marked ready become sellable at the stored trade rate.',
   '{pricing_updated_at}', '', 30),

  ('customer_records', 'zone_id', 'Zone', 'enum',
   '[]'::jsonb,
   $$select z.id::text as value, z.name as label from public.zones z where z.is_active order by z.id$$,
   null, null, 'Which operating zone serves these customers.',
   'Delivery, inquiry routing and the zone scope all follow the new zone.',
   '{}', '', 10),

  ('customer_records', 'approved', 'Approved to order', 'bool',
   '[]'::jsonb, '', null, null,
   'An unapproved customer can sign in but cannot place orders.',
   'Removing approval stops these customers from placing new orders.',
   '{approved_at, approved_by}',
   $$approved_at = case when ($1::text::boolean) then now() else null end,
     approved_by = case when ($1::text::boolean) then public.audit_actor()->>'email' else null end$$,
   20),

  ('customer_records', 'is_deleted', 'Soft-delete', 'bool',
   '[]'::jsonb, '', null, null,
   'A soft-deleted customer disappears from every list but nothing is destroyed — undo restores it whole.',
   'These customers vanish from the admin lists. Nothing is erased; this is reversible.',
   '{deleted_at, deleted_by}',
   $$deleted_at = case when ($1::text::boolean) then now() else null end,
     deleted_by = case when ($1::text::boolean) then public.audit_actor()->>'email' else null end$$,
   30),

  ('supplier_records', 'zone_id', 'Zone', 'enum',
   '[]'::jsonb,
   $$select z.id::text as value, z.name as label from public.zones z where z.is_active order by z.id$$,
   null, null,
   'Supplier zone normally follows the district — set it here only deliberately.',
   'Every future inquiry and purchase order for these suppliers routes to the new zone.',
   '{}', '', 10),

  ('supplier_records', 'status', 'Status', 'enum',
   '[{"value":"Active","label":"Active"},{"value":"Paused","label":"Paused"},{"value":"Inactive","label":"Inactive"}]'::jsonb,
   '', null, null, 'Paused and inactive suppliers are skipped by the inquiry waterfall.',
   'Paused and inactive suppliers stop receiving inquiries.',
   '{}', '', 20),

  ('supplier_records', 'is_deleted', 'Soft-delete', 'bool',
   '[]'::jsonb, '', null, null,
   'A soft-deleted supplier disappears from every list but nothing is destroyed — undo restores it whole.',
   'These suppliers vanish from the admin lists. Nothing is erased; this is reversible.',
   '{deleted_at, deleted_by}',
   $$deleted_at = case when ($1::text::boolean) then now() else null end,
     deleted_by = case when ($1::text::boolean) then public.audit_actor()->>'email' else null end$$,
   30),

  ('order_status', 'status', 'Status', 'enum',
   '[{"value":"pending","label":"Pending"},{"value":"accepted","label":"Accepted"},{"value":"processing","label":"Processing"}]'::jsonb,
   '', null, null,
   'Only the pre-fulfilment statuses. Packed, delivered, billed and cancelled orders are not in this list.',
   'These orders move to the new status. Billing and packing are untouched.',
   '{}', '', 10)
on conflict (target_key, field) do update set
  label = excluded.label, input_kind = excluded.input_kind, options = excluded.options,
  options_sql = excluded.options_sql, min_value = excluded.min_value,
  max_value = excluded.max_value, hint = excluded.hint,
  confirm_body = excluded.confirm_body, snapshot_cols = excluded.snapshot_cols,
  extra_set = excluded.extra_set, sort_order = excluded.sort_order, is_active = true;
