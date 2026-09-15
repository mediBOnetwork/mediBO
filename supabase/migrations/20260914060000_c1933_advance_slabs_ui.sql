-- CMD #1933 — the Advance ladder gets a DOOR, a card and a permissions row.
--
-- CMD #1932 built the ladder: the table, the resolver, the freeze trigger and
-- four render-ready RPCs. What it did not build is the half a feature only
-- exists with (§11): the tile sat in a "Billing" group under the system
-- category — a place no phone has a way into — the card had a bare Switch
-- where the Discount-slabs card has worded actions, a read-only admin was
-- shown the same card with the buttons silently missing and no sentence
-- saying why, the super admin had no way to hand an admin write access
-- without leaving for the users screen, and the checkout never mentioned the
-- advance the pharmacy is about to be asked for.
--
-- Everything below is DATA and BACKEND WORDING. The screen in this change
-- prints what these functions return and decides nothing.

-- ─────────────────────────────────────────────────────────────────────────
-- 1. THE DOOR — More ▸ Catalogue & pricing, beside Discount slabs
-- ─────────────────────────────────────────────────────────────────────────
-- Discount slabs sits at sort_order 60 in 'more_catalogue'. The ladder is the
-- other half of the same conversation (what the pharmacy pays up front vs what
-- it is charged), so it sits at 65 — immediately after it, never before the
-- catalogue tiles.
-- The 'Catalogue & pricing' grid itself. It already exists on live (#1016);
-- a fresh build branch carries only a skeleton nav_category, and without this
-- row _feature_registry_home_guard sees a category with no home tab and parks
-- the tile in the More grid instead — the tile would be reachable but in the
-- wrong place, which is exactly the bug this command exists to fix.
insert into public.ui_icon (icon_key, label) values ('book','Book')
on conflict (icon_key) do nothing;

insert into public.nav_category (category_key, label, icon_key, sort_order, is_active, home_tab)
values ('more_catalogue', 'Catalogue & pricing', 'book', 61, true, 'more')
on conflict (category_key) do update
   set home_tab  = coalesce(public.nav_category.home_tab, excluded.home_tab),
       is_active = true;

update public.feature_registry
   set label       = 'Advance slabs',
       group_label = 'Catalogue & pricing',
       category    = 'more_catalogue',
       sort_order  = 65,
       surface     = 'dashboard',
       icon_key    = 'percent',
       deep_link   = '/admin/go/advance_slabs',
       search_terms = 'advance slabs ladder rung percent upfront billing catalogue pricing',
       description  = 'Advance % by how many orders the pharmacy has already paid in full, per zone.',
       is_active    = true
 where feature_key = 'advance_slabs';

-- The row is #1932's, but a build branch that replays these files in order
-- must not depend on that: if it is somehow absent, place it.
insert into public.feature_registry
  (feature_key, label, group_label, surface, route_key, icon_key, partner_eligible,
   sort_order, category, description, search_terms, deep_link, is_active)
select 'advance_slabs', 'Advance slabs', 'Catalogue & pricing', 'dashboard',
       'advance_slabs', 'percent', true, 65, 'more_catalogue',
       'Advance % by how many orders the pharmacy has already paid in full, per zone.',
       'advance slabs ladder rung percent upfront billing catalogue pricing',
       '/admin/go/advance_slabs', true
 where not exists (select 1 from public.feature_registry
                    where feature_key = 'advance_slabs');

insert into public.surface_route (route_key, feature_key, kind, handled_by, note)
values ('advance_slabs', 'advance_slabs', 'feature', 'home_shell',
        'CMD #1933 — Advance slabs, More ▸ Catalogue & pricing, opened from shell/shell_extra_routes.dart')
on conflict (route_key, feature_key) do update
   set handled_by = excluded.handled_by, kind = excluded.kind,
       note = excluded.note, is_active = true;

-- ─────────────────────────────────────────────────────────────────────────
-- 2. COPY — every new string this change puts on a screen
-- ─────────────────────────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('advance_slabs.nav_label',        to_jsonb('Advance slabs'::text)),
  ('advance_slabs.title',            to_jsonb('Advance slabs'::text)),
  ('advance_slabs.read_only_hint',   to_jsonb('View only — ask super admin for edit access'::text)),
  ('advance_slabs.activate_label',   to_jsonb('Activate'::text)),
  ('advance_slabs.deactivate_label', to_jsonb('Deactivate'::text)),
  ('advance_slabs.effective_fmt',    to_jsonb('From {d}'::text)),
  ('advance_slabs.delete_confirm',   to_jsonb('Delete this rung?'::text)),
  ('advance_slabs.cancel_label',     to_jsonb('Cancel'::text)),
  ('advance_slabs.access_title',     to_jsonb('Who can edit'::text)),
  ('advance_slabs.access_sub',       to_jsonb('Admins and partners, by zone. Read shows the ladder; Write lets them change it.'::text)),
  ('advance_slabs.access_read',      to_jsonb('Read'::text)),
  ('advance_slabs.access_write',     to_jsonb('Write'::text)),
  ('advance_slabs.access_empty',     to_jsonb('No admins or partners to grant yet.'::text)),
  ('advance_slabs.access_saved',     to_jsonb('Access updated'::text)),
  ('advance_slabs.access_super_note',to_jsonb('Always on for a super admin.'::text)),
  ('advance_slabs.access_denied',    to_jsonb('Only a mediBO super admin can change who edits the ladder.'::text)),
  ('advance.cart_line_fmt',          to_jsonb('Advance {pct} ({ord} order) · {amt}'::text)),
  ('advance.cart_label',             to_jsonb('Advance on this order'::text))
on conflict (key) do update set value = excluded.value
 where public.ui_copy.key in ('advance_slabs.title','advance_slabs.nav_label');

-- ─────────────────────────────────────────────────────────────────────────
-- 3. THE LIST — three additions, nothing removed
-- ─────────────────────────────────────────────────────────────────────────
--   read_only_hint   the sentence a read-only admin gets INSTEAD of silence
--   toggle_label /   the Discount-slabs card has worded actions, not a Switch:
--   toggle_to        the backend says "Deactivate" and what the tap means
--   effective_label  "From 14 Sep 2026" — the valid_from, worded here
create or replace function public.advance_slabs_list()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_zone smallint; v_date date; v_super boolean; v_write boolean;
  v_rows jsonb; v_zones jsonb;
begin
  if not public.access_can('advance_slabs','read') then
    return public.access_denied('advance_slabs','read')
           || jsonb_build_object('retry_label',
                coalesce(nullif(public._c('advance_slabs.retry'),''),'Try again'));
  end if;
  v_zone  := public.admin_active_zone();      -- NULL = all zones (super admin)
  v_date  := public.admin_active_date();
  v_super := coalesce((public.access_subject()->>'role') = 'super_admin', false);
  v_write := public.access_can('advance_slabs','write');

  select coalesce(jsonb_agg(r order by r->>'sort_key'), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'id', s.id,
      'sort_key', case when s.zone_id is null then '0000' else lpad(s.zone_id::text, 4, '0') end
                  || '-' || lpad(s.order_no::text, 4, '0'),
      'order_no', s.order_no,
      'order_label', replace(coalesce(nullif(public._c('advance_slabs.rung_label'),''), '{ord} order onwards'),
                             '{ord}', public._advance_ordinal(s.order_no)),
      'pct', s.pct,
      'pct_label', public._advance_pct_text(s.pct) || '%',
      'zone_id', s.zone_id,
      'zone_label', coalesce(z.name, nullif(public._c('advance_slabs.zone_all'),''), 'All zones'),
      'active', s.active,
      'status_label', case when s.active
                           then coalesce(nullif(public._c('advance_slabs.active_label'),''),'Active')
                           else coalesce(nullif(public._c('advance_slabs.off_label'),''),'Off') end,
      'status_tone', case when s.active then 'success' else 'warning' end,
      'in_force', (s.active and s.valid_from <= v_date),
      'valid_from', s.valid_from,
      'effective_label', replace(coalesce(nullif(public._c('advance_slabs.effective_fmt'),''),'From {d}'),
                                 '{d}', to_char(s.valid_from, 'DD Mon YYYY')),
      'toggle_to', (not s.active),
      'toggle_label', case when s.active
                           then coalesce(nullif(public._c('advance_slabs.deactivate_label'),''),'Deactivate')
                           else coalesce(nullif(public._c('advance_slabs.activate_label'),''),'Activate') end,
      'note', coalesce(s.note,''),
      'used_count', u.n,
      'used_label', case
        when u.n = 1 then coalesce(nullif(public._c('advance_slabs.used_label_one'),''),'On 1 order')
        when u.n > 1 then replace(coalesce(nullif(public._c('advance_slabs.used_label'),''),'On {n} orders'), '{n}', u.n::text)
        else coalesce(nullif(public._c('advance_slabs.unused_label'),''),'Not used yet') end,
      'can_edit', (v_write and (v_super or (s.zone_id is not null and s.zone_id = v_zone))),
      'can_delete', (v_write and u.n = 0 and (v_super or (s.zone_id is not null and s.zone_id = v_zone)))
    ) r
    from public.advance_slabs s
    left join public.zones z on z.id = s.zone_id
    cross join lateral (
      select count(*)::int n from public.orders o where o.advance_slab_id = s.id
    ) u
    where v_zone is null or s.zone_id is null or s.zone_id = v_zone
  ) t;

  select coalesce(jsonb_agg(jsonb_build_object('id', z.id, 'label', z.name) order by z.name), '[]'::jsonb)
    into v_zones
    from public.zones z
   where coalesce(z.is_active, true)
     and (v_zone is null or z.id = v_zone);

  return jsonb_build_object(
    'ok', true,
    'title',    coalesce(nullif(public._c('advance_slabs.title'),''),'Advance slabs'),
    'subtitle', public._c('advance_slabs.subtitle'),
    'hint',     public._c('advance_slabs.zone_hint'),
    'add_label',coalesce(nullif(public._c('advance_slabs.add_label'),''),'Add slab'),
    'empty_text', public._c('advance_slabs.empty'),
    'can_write', v_write,
    'can_add_all_zones', v_super,
    -- A read-only admin is TOLD it is read-only; the missing buttons are not
    -- left to be inferred from an empty space.
    'read_only_hint', case when v_write then ''
      else coalesce(nullif(public._c('advance_slabs.read_only_hint'),''),
                    'View only — ask super admin for edit access') end,
    'zone_id', v_zone,
    'zone_label', coalesce((select z.name from public.zones z where z.id = v_zone),
                           nullif(public._c('advance_slabs.zone_all'),''), 'All zones'),
    'all_zones_label', coalesce(nullif(public._c('advance_slabs.zone_all'),''),'All zones'),
    'active_date', to_char(v_date, 'DD Mon YYYY'),
    'columns', jsonb_build_array(
      jsonb_build_object('key','order_label','label', coalesce(nullif(public._c('advance_slabs.col_order'),''),'Order'),'align','left'),
      jsonb_build_object('key','pct_label',  'label', coalesce(nullif(public._c('advance_slabs.col_pct'),''),'Advance'),'align','right'),
      jsonb_build_object('key','zone_label', 'label', coalesce(nullif(public._c('advance_slabs.col_zone'),''),'Zone'),'align','left'),
      jsonb_build_object('key','status_label','label', coalesce(nullif(public._c('advance_slabs.col_status'),''),'Status'),'align','left')),
    'retry_label', coalesce(nullif(public._c('advance_slabs.retry'),''),'Try again'),
    'edit_label',  coalesce(nullif(public._c('advance_slabs.edit_label'),''),'Edit'),
    'delete_label',coalesce(nullif(public._c('advance_slabs.delete_label'),''),'Delete'),
    'delete_confirm', coalesce(nullif(public._c('advance_slabs.delete_confirm'),''),'Delete this rung?'),
    'cancel_label', coalesce(nullif(public._c('advance_slabs.cancel_label'),''),'Cancel'),
    'access_title', coalesce(nullif(public._c('advance_slabs.access_title'),''),'Who can edit'),
    'show_access', v_super,
    'form', jsonb_build_object(
      'add_title',    coalesce(nullif(public._c('advance_slabs.add_title'),''),'New rung'),
      'edit_title',   coalesce(nullif(public._c('advance_slabs.edit_title'),''),'Edit rung'),
      'save_label',   coalesce(nullif(public._c('advance_slabs.save_label'),''),'Save rung'),
      'order_label',  coalesce(nullif(public._c('advance_slabs.field_order'),''),'Applies from the customer''s nth order'),
      'pct_label',    coalesce(nullif(public._c('advance_slabs.field_pct'),''),'Advance % of MRP'),
      'zone_label',   coalesce(nullif(public._c('advance_slabs.field_zone'),''),'Zone'),
      'from_label',   coalesce(nullif(public._c('advance_slabs.field_from'),''),'Valid from'),
      'note_label',   coalesce(nullif(public._c('advance_slabs.field_note'),''),'Note (optional)'),
      'active_label', coalesce(nullif(public._c('advance_slabs.field_active'),''),'Rung is on')),
    'zones', v_zones,
    'rows', v_rows);
end $$;

insert into public.ui_copy (key, value) values
  ('advance_slabs.field_from', to_jsonb('Valid from'::text)),
  ('advance_slabs.add_label',  to_jsonb('Add slab'::text))
on conflict (key) do update set value = excluded.value;

-- ─────────────────────────────────────────────────────────────────────────
-- 4. WHO CAN EDIT — the #307 matrix, narrowed to this one feature
-- ─────────────────────────────────────────────────────────────────────────
-- The full users-and-access screen already exists; what did not exist is
-- answering "who can change the Bilaspur ladder?" from the ladder itself.
-- These two read and write the SAME access_grant rows through the same
-- guard, so there is one permission truth and not a second one here.
create or replace function public.advance_slabs_access_list()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_rows jsonb;
begin
  if not public._access_admin_ok() then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'title',   coalesce(nullif(public._c('advance_slabs.access_title'),''),'Who can edit'),
      'message', coalesce(nullif(public._c('advance_slabs.access_denied'),''),
                          'Only a mediBO super admin can change who edits the ladder.'));
  end if;

  select coalesce(jsonb_agg(r order by r->>'sort_key'), '[]'::jsonb) into v_rows from (
    select jsonb_build_object(
      'kind','admin', 'id', a.id::text,
      'name', a.email,
      'role_label', case when coalesce(a.is_super,false)
                         then coalesce(nullif(public._c('users_access.super_label'),''),'Super admin')
                         else coalesce(nullif(public._c('users_access.admin_label'),''),'Admin') end,
      'zone_label', coalesce(z.name, nullif(public._c('advance_slabs.zone_all'),''), 'All zones'),
      'locked', coalesce(a.is_super,false),
      'locked_note', case when coalesce(a.is_super,false)
                          then coalesce(nullif(public._c('advance_slabs.access_super_note'),''),
                                        'Always on for a super admin.') else '' end,
      'can_view',  coalesce(e.can_view, false),
      'can_write', coalesce(e.can_write, false),
      'sort_key', '0' || case when coalesce(a.is_super,false) then '0' else '1' end || a.email) r
      from public.admins a
      left join public.zones z on z.id = a.zone_id
      left join lateral (select x.can_view, x.can_write
                           from public.access_effective('admin', a.id::text) x
                          where x.feature_key = 'advance_slabs') e on true
    union all
    select jsonb_build_object(
      'kind','partner', 'id', rp.id::text,
      'name', rp.partner_name,
      'role_label', coalesce(nullif(public._c('users_access.partner_org_label'),''),'Partner'),
      'zone_label', coalesce(z.name, nullif(public._c('advance_slabs.zone_all'),''), 'All zones'),
      'locked', false, 'locked_note', '',
      'can_view',  coalesce(e.can_view, false),
      'can_write', coalesce(e.can_write, false),
      'sort_key', '1' || rp.partner_name) r
      from public.region_partners rp
      left join public.zones z on z.id = rp.zone_id
      left join lateral (select x.can_view, x.can_write
                           from public.access_effective('partner', rp.id::text) x
                          where x.feature_key = 'advance_slabs') e on true
     where coalesce(rp.is_active, true)
  ) q(r);

  return jsonb_build_object(
    'ok', true,
    'title',       coalesce(nullif(public._c('advance_slabs.access_title'),''),'Who can edit'),
    'subtitle',    coalesce(nullif(public._c('advance_slabs.access_sub'),''),''),
    'read_label',  coalesce(nullif(public._c('advance_slabs.access_read'),''),'Read'),
    'write_label', coalesce(nullif(public._c('advance_slabs.access_write'),''),'Write'),
    'empty_text',  coalesce(nullif(public._c('advance_slabs.access_empty'),''),
                            'No admins or partners to grant yet.'),
    'rows', v_rows);
end $$;

create or replace function public.advance_slabs_access_set(
  p_kind text, p_id text, p_can_view boolean, p_can_write boolean)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_res jsonb;
begin
  if not public._access_admin_ok() then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', coalesce(nullif(public._c('advance_slabs.access_denied'),''),
                          'Only a mediBO super admin can change who edits the ladder.'));
  end if;
  -- Write implies read: a subject that may change the ladder can obviously see
  -- it, and a matrix that let those two disagree would be a bug store.
  v_res := public.access_matrix_set(p_kind, p_id, 'advance_slabs',
                                    coalesce(p_can_view, false) or coalesce(p_can_write, false),
                                    coalesce(p_can_write, false));
  if coalesce((v_res->>'ok')::boolean, false) then
    v_res := v_res || jsonb_build_object('message',
      coalesce(nullif(public._c('advance_slabs.access_saved'),''),'Access updated'));
  end if;
  return v_res;
end $$;

grant execute on function public.advance_slabs_access_list() to authenticated;
grant execute on function public.advance_slabs_access_set(text, text, boolean, boolean) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 5. CHECKOUT — the pharmacy is told what it is about to be asked for
-- ─────────────────────────────────────────────────────────────────────────
-- The order panel already prints the FROZEN rung (#1932). Before the order
-- exists there is nothing frozen yet, so the cart resolves the rung the order
-- WOULD freeze and words the line here. One sentence, built in SQL:
--   "Advance 15% (2nd order) · ₹1,200"
create or replace function public.cart_selected_total(p_product_ids text[])
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_cust uuid := coalesce(public.customer_id_for_user(public.viewer_cart_user()),
                                public.my_customer_id());
        v_uid uuid := public.viewer_cart_user();
        v_total numeric; v_lines int; v_units int;
        v_zone smallint; v_adv jsonb; v_amt numeric; v_line text;
begin
  if auth.uid() is null then raise exception 'not_signed_in' using errcode='28000'; end if;
  select coalesce(sum(round(coalesce(ci.quantity,0) * coalesce(ci.mrp,0), 2)), 0),
         count(*), coalesce(sum(coalesce(ci.quantity,0)),0)
    into v_total, v_lines, v_units
  from cart_items ci
   where (case when v_cust is not null then ci.customer_id = v_cust else ci.user_id = v_uid end)
     and (p_product_ids is null or ci.product_id = any(p_product_ids))
     and coalesce(ci.removed_by_admin,false) = false;

  -- CMD #1933 — the advance line. Never allowed to break a cart: any failure
  -- leaves the line empty and the totals exactly as they were.
  begin
    if v_cust is not null and v_total > 0 then
      select pp.zone_id into v_zone from public.pharmacy_profiles pp where pp.id = v_cust;
      v_adv := public.advance_pct_for(v_cust, v_zone);
      v_amt := round(v_total * coalesce((v_adv->>'pct')::numeric, 0) / 100.0, 2);
      v_line := replace(replace(replace(
                  coalesce(nullif(public._c('advance.cart_line_fmt'),''),
                           'Advance {pct} ({ord} order) · {amt}'),
                  '{pct}', coalesce(v_adv->>'pct_label','')),
                  '{ord}', public._advance_ordinal(coalesce((v_adv->>'order_no')::int, 1))),
                  '{amt}', public.inr_money(v_amt));
    end if;
  exception when others then
    v_line := null; v_amt := null;
  end;

  return jsonb_build_object(
    'total', v_total,
    'total_display', public.inr_money(v_total),
    'subtotal', v_total,
    'subtotal_display', public.inr_money(v_total),
    'item_count', v_lines,
    'unit_count', v_units,
    'advance_label', case when v_line is null then ''
                          else coalesce(nullif(public._c('advance.cart_label'),''),'Advance on this order') end,
    'advance_line', coalesce(v_line, ''),
    'advance_amount', v_amt,
    'advance_pct_label', coalesce(v_adv->>'pct_label',''),
    'subtotal_line', case when v_lines = 1 then '1 item' else v_lines::text || ' items' end
                     || ' • MRP worth ' || public.inr_money(v_total));
end $$;

-- ─────────────────────────────────────────────────────────────────────────
-- 6. SAVE — an edit no longer rewinds valid_from to the year 2000
-- ─────────────────────────────────────────────────────────────────────────
-- #1932 read valid_from out of the patch with a fixed fallback, and the sheet
-- had no field for it. Editing a rung's percentage therefore silently reset
-- the date it takes effect from. The field exists on the sheet now, and the
-- fallback is the rung's OWN date, so an old client that omits the key still
-- cannot move it.
create or replace function public.advance_slab_save(p jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_id bigint; v_zone smallint; v_order_no int; v_pct numeric;
  v_active boolean; v_from date; v_note text; v_gate jsonb; v_old public.advance_slabs%rowtype;
begin
  v_id       := nullif(p->>'id','')::bigint;
  v_zone     := nullif(p->>'zone_id','')::smallint;
  v_order_no := nullif(p->>'order_no','')::int;
  v_pct      := nullif(p->>'pct','')::numeric;
  v_active   := coalesce((p->>'active')::boolean, true);
  v_from     := nullif(p->>'valid_from','')::date;
  v_note     := nullif(btrim(coalesce(p->>'note','')),'');

  if v_id is not null then
    select * into v_old from public.advance_slabs where id = v_id;
    if not found then
      return jsonb_build_object('ok', false, 'error','not_found',
        'message', coalesce(nullif(public._c('advance_slabs.not_found'),''),'That rung no longer exists.'));
    end if;
    v_zone := coalesce(v_zone, v_old.zone_id);
    v_from := coalesce(v_from, v_old.valid_from);
    -- A non-super caller may not move a rung out of the zone they own.
    v_gate := public._advance_slab_can_write(v_old.zone_id);
    if not (v_gate->>'ok')::boolean then return v_gate; end if;
  end if;
  v_from := coalesce(v_from, '2000-01-01'::date);

  v_gate := public._advance_slab_can_write(v_zone);
  if not (v_gate->>'ok')::boolean then return v_gate; end if;

  if v_order_no is null or v_order_no < 1 then
    return jsonb_build_object('ok', false, 'error','bad_order_no',
      'message', coalesce(nullif(public._c('advance_slabs.bad_order_no'),''),'Order number must be 1 or more.'));
  end if;
  if v_pct is null or v_pct < 0 or v_pct > 100 then
    return jsonb_build_object('ok', false, 'error','bad_pct',
      'message', coalesce(nullif(public._c('advance_slabs.bad_pct'),''),'Advance % must be between 0 and 100.'));
  end if;

  begin
    if v_id is null then
      insert into public.advance_slabs (zone_id, order_no, pct, active, valid_from, note, created_by)
      values (v_zone, v_order_no, v_pct, v_active, v_from, v_note,
              coalesce(public.access_subject()->>'id',''))
      returning id into v_id;
    else
      update public.advance_slabs
         set zone_id = v_zone, order_no = v_order_no, pct = v_pct,
             active = v_active, valid_from = v_from, note = v_note, updated_at = now()
       where id = v_id;
    end if;
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'error','duplicate',
      'message', coalesce(nullif(public._c('advance_slabs.duplicate'),''),
                          'That zone already has a rung for this order number.'));
  end;

  return jsonb_build_object('ok', true, 'id', v_id,
    'message', coalesce(nullif(public._c('advance_slabs.saved'),''),'Rung saved'));
end $$;

-- ─────────────────────────────────────────────────────────────────────────
-- 7. CHECKOUT — the advance row in the cart's own totals ladder
-- ─────────────────────────────────────────────────────────────────────────
-- The ladder the cart prints is `summary.rows`, rendered in payload order by
-- C572TotalsBlock. The advance therefore arrives as a ROW — label and amount
-- both worded here — rather than as a new widget:
--     Advance 15% (2nd order)              ₹1,200.00
-- It sits under MRP total because that is what it is a percentage OF, and it
-- is resolved (not frozen) because the order does not exist yet; the order
-- panel prints the frozen rung once it does (#1932).
insert into public.ui_copy (key, value) values
  ('advance.cart_row_label', to_jsonb('Advance {pct} ({ord} order)'::text))
on conflict (key) do nothing;

create or replace function public.cart_summary_block(p_pricing jsonb, p_delivery jsonb, p_items_label text, p_grand_display text, p_mrp_total numeric, p_item_count integer)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $function$
declare
  v_net      numeric := coalesce((p_pricing->>'net_payable')::numeric, 0);
  v_unpriced int     := coalesce((p_pricing->>'unpriced_count')::int, 0);
  v_priced   int     := coalesce((p_pricing->>'priced_count')::int, 0);
  v_has      boolean := (v_net > 0);
  v_rows     jsonb   := '[]'::jsonb;
  v_line     text;
  v_cust     uuid; v_zone smallint; v_adv jsonb; v_adv_label text;
begin
  if not v_has then
    v_line := public._cf('cart.summary_pending', jsonb_build_object('items', p_items_label));
  elsif v_unpriced > 0 then
    v_line := public._cf('cart.summary_partial',
                jsonb_build_object('items', p_items_label, 'pending', v_unpriced::text));
  else
    v_line := public._cf('cart.summary_priced', jsonb_build_object('items', p_items_label));
  end if;

  -- Items — the count, as a number against a plain label.
  v_rows := v_rows || jsonb_build_array(jsonb_build_object(
    'key','items','label', public._c('cart.summary_items_label'),
    'amount', coalesce(p_item_count,0)::text, 'strong', false));

  -- MRP total — the printed ceiling, reference only.
  v_rows := v_rows || jsonb_build_array(jsonb_build_object(
    'key','mrp_total','label', public._c('cart.summary_mrp_label'),
    'amount', public.inr_money(coalesce(p_mrp_total,0)), 'strong', false));

  -- CMD #1933 — which rung of the advance ladder this basket would freeze.
  -- Never allowed to break a cart: any failure simply omits the row.
  begin
    v_cust := coalesce(public.customer_id_for_user(public.viewer_cart_user()),
                       public.my_customer_id());
    if v_cust is not null and coalesce(p_mrp_total,0) > 0 then
      select pp.zone_id into v_zone from public.pharmacy_profiles pp where pp.id = v_cust;
      v_adv := public.advance_pct_for(v_cust, v_zone);
      v_adv_label := replace(replace(
        coalesce(nullif(public._c('advance.cart_row_label'),''),'Advance {pct} ({ord} order)'),
        '{pct}', coalesce(v_adv->>'pct_label','')),
        '{ord}', public._advance_ordinal(coalesce((v_adv->>'order_no')::int, 1)));
      v_rows := v_rows || jsonb_build_array(jsonb_build_object(
        'key','advance', 'label', v_adv_label,
        'amount', public.inr_money(
          round(coalesce(p_mrp_total,0) * coalesce((v_adv->>'pct')::numeric,0) / 100.0, 2)),
        'strong', false));
    end if;
  exception when others then
    null;
  end;

  if v_has then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'key','net','label', coalesce(p_pricing->>'net_payable_label','Net payable'),
      'amount', coalesce(p_pricing->>'net_payable_display',''), 'strong', false));
  end if;

  if coalesce((p_delivery->>'has')::boolean, false) then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'key','delivery','label', coalesce(p_delivery->>'label',''),
      'amount', coalesce(p_delivery->>'amount_display',''), 'strong', false));
    if coalesce((p_delivery->>'has_gst')::boolean, false) then
      v_rows := v_rows || jsonb_build_array(jsonb_build_object(
        'key','delivery_gst','label', coalesce(p_delivery->>'gst_label',''),
        'amount', coalesce(p_delivery->>'gst_display',''), 'strong', false));
    end if;
  end if;

  if v_has then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'key','grand','label', public._c('cart.grand_total_label'),
      'amount', p_grand_display, 'strong', true));
  end if;

  return jsonb_build_object(
    'line',           v_line,
    'delivery_note',  coalesce(p_delivery->>'note',''),
    'has_amount',     v_has,
    'show_line',      v_has,
    'amount_display', case when v_has then coalesce(p_pricing->>'net_payable_display','') else '' end,
    'priced_count',   v_priced,
    'unpriced_count', v_unpriced,
    'rate_note',      case when v_unpriced > 0 then public._c('cart.rate_note') else '' end,
    'rows',           v_rows);
end
$function$;
