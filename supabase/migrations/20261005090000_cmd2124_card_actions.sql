-- CMD #2124 — card actions: + opens the qty picker, the chosen qty shows on the
-- button, unavailable offers Notify and then Notified.
--
-- The card object (#2121) already carried cta/foot for the state it was built
-- in. What it could not say is what the card should print AFTER a tap made on
-- the phone, before the next read: the picked quantity on the pill, the "tap
-- to change" line, the Notified button and its WhatsApp line. So the card now
-- carries an `action` block with every word for every state it can move to —
-- the widget swaps between backend strings, it never composes one.
-- Idempotent: labels upsert, functions are CREATE OR REPLACE.

insert into storefront_ui_label(key, value, note) values
  ('card_notify_short',   'Notify',   'CMD #2124 card Notify button (outlined, bell)'),
  ('card_notified_label', 'Notified', 'CMD #2124 card button once the notify request is stored'),
  ('card_qty_foot',       '{qty} {unit} in cart · tap to change', 'CMD #2124 card foot while the pack is in the cart; {qty}/{unit} filled'),
  ('card_qty_remove',     'Remove',   'CMD #2124 the 0 row of the card qty picker'),
  ('card_foot_notified',  'We''ll WhatsApp you when it''s back', 'CMD #2124 card foot once notified (was CMD #2122 wording)')
on conflict (key) do update set value = excluded.value, note = excluded.note, updated_at = now();

-- The card's picker: the SAME bulk_qty_picker list (cap from ui_copy, 999),
-- plus a 0 "Remove" row on top once the pack is in the cart.
create or replace function public.card_qty_picker(p_pack_type text default null, p_current integer default null)
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  with b as (select public.bulk_qty_picker(p_pack_type, p_current) as j)
  select case
    when coalesce(p_current, 0) > 0 then
      b.j || jsonb_build_object(
        'min', 0,
        'selected_index', coalesce((b.j->>'selected_index')::int, 0) + 1,
        'options', jsonb_build_array(jsonb_build_object('value', 0,
                     'label', coalesce((select value from storefront_ui_label where key='card_qty_remove'), ''),
                     'remove', true))
                   || coalesce(b.j->'options', '[]'::jsonb))
    else b.j end
  from b;
$$;
revoke all on function public.card_qty_picker(text, integer) from public, anon;
grant execute on function public.card_qty_picker(text, integer) to authenticated, service_role;

-- Every word the card's action can move to, filled for this pack.
create or replace function public._product_card_action(m "MEDICINE", p_qty integer, p_notified boolean)
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  with u as (select public.bulk_qty_unit(m.pack_type) as unit,
                    greatest(coalesce(p_qty, 0), 0) as qty)
  select jsonb_build_object(
    'picker', jsonb_build_object('rpc', 'card_qty_picker', 'pack_type', coalesce(m.pack_type, '')),
    -- "{qty} strip" — the pill; the same template the picker rows print.
    'qty_tpl', replace(public.uic('bulk.qty_line', '{qty} {unit}'), '{unit}', u.unit),
    'qty_label', case when u.qty > 0 then public.bulk_qty_line(u.qty, m.pack_type) else '' end,
    -- "{qty} strip in cart · tap to change" — the foot while it is in the cart.
    'qty_foot_tpl', replace(coalesce((select value from storefront_ui_label where key='card_qty_foot'), ''),
                            '{unit}', u.unit),
    'qty_foot', case when u.qty > 0 then
                  replace(replace(coalesce((select value from storefront_ui_label where key='card_qty_foot'), ''),
                                  '{unit}', u.unit), '{qty}', u.qty::text)
                else '' end,
    'notify', jsonb_build_object(
      'rpc', 'stock_notify_request',
      'notified', coalesce(p_notified, false),
      'label', coalesce((select value from storefront_ui_label where key='card_notify_short'), ''),
      'done_label', coalesce((select value from storefront_ui_label where key='card_notified_label'), ''),
      'idle_line', coalesce((select value from storefront_ui_label where key='card_foot_unavailable'), ''),
      'done_line', coalesce((select value from storefront_ui_label where key='card_foot_notified'), ''),
      'tone', jsonb_build_object('name','danger','bg','#FEE2E2','fg','#991B1B')))
  from u;
$$;
revoke all on function public._product_card_action("MEDICINE", integer, boolean) from public, anon;

-- The foot while in the cart is the action's "tap to change" line when the
-- card carries one; everything else is #2122's order, unchanged.
create or replace function public._product_card_foot(p_card jsonb, p_scheme_line text default ''::text)
returns jsonb
language sql stable security definer set search_path to 'public'
as $function$
  with l as (select
      (select value from storefront_ui_label where key='card_foot_unavailable') as unavail,
      (select value from storefront_ui_label where key='card_foot_notified')    as notified,
      (select value from storefront_ui_label where key='card_foot_locked')      as locked),
  f as (
    select case
      when p_card is null then null
      when not coalesce((p_card#>>'{availability,is_available}')::boolean, false)
           and coalesce((p_card->>'notified')::boolean, false) then
        jsonb_build_object('label', coalesce(l.notified, ''),
          'tone', jsonb_build_object('name','muted','bg','#F3F4F6','fg','#6B7280'))
      when not coalesce((p_card#>>'{availability,is_available}')::boolean, false) then
        jsonb_build_object('label', coalesce(l.unavail, nullif(p_card#>>'{availability,label}', ''), ''),
          'tone', jsonb_build_object('name','danger','bg','#FEE2E2','fg','#991B1B'))
      when coalesce((p_card->>'qty_in_cart')::int, 0) > 0 then
        jsonb_build_object('label', coalesce(nullif(p_card#>>'{action,qty_foot}', ''), p_card#>>'{cta,label}', ''),
          'tone', jsonb_build_object('name','brand','bg','#D1FAE5','fg','#1B7A43'))
      when coalesce((p_card->>'locked')::boolean, false) then
        jsonb_build_object('label', coalesce(l.locked, p_card#>>'{price,locked_note}', ''),
          'tone', jsonb_build_object('name','muted','bg','#F3F4F6','fg','#6B7280'))
      when coalesce(p_scheme_line, '') <> '' then
        jsonb_build_object('label', p_scheme_line,
          'tone', jsonb_build_object('name','brand','bg','#D1FAE5','fg','#1B7A43'))
      when coalesce((p_card#>>'{price,has_margin}')::boolean, false)
           and coalesce(p_card#>>'{price,margin_label}', '') <> '' then
        jsonb_build_object('label', p_card#>>'{price,margin_label}',
          'tone', jsonb_build_object('name','brand','bg','#D1FAE5','fg','#1B7A43'))
      else
        jsonb_build_object('label', coalesce(p_card#>>'{availability,label}', ''),
          'tone', jsonb_build_object('name','success','bg','#D1FAE5','fg','#065F46'))
    end as foot
    from l)
  select case when f.foot is null then null
              else f.foot || jsonb_build_object('has', coalesce(f.foot->>'label', '') <> '') end
    from f;
$function$;

create or replace function public._product_card(m "MEDICINE", p_pricing jsonb, p_avail jsonb, p_qty integer, p_notified boolean)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  v_img   text := nullif(btrim(coalesce(m.image_url_1, '')), '');
  v_avail boolean := coalesce((p_avail->>'is_available')::boolean, false);
  v_price jsonb := coalesce(p_pricing->'card_price', '{}'::jsonb);
  v_locked boolean := coalesce((v_price->>'price_locked')::boolean, true)
                      and not public.viewer_is_approved_customer();
  v_qty   int := greatest(coalesce(p_qty, 0), 0);
  v_offer text;
  v_card  jsonb;
  v_scheme text := coalesce(p_pricing#>>'{scheme_effective,label}', '');
begin
  v_offer := case
    when coalesce((p_pricing->>'has_scheme')::boolean, false)
      then coalesce(p_pricing#>>'{scheme_badge,label}', p_pricing->>'scheme_text', '')
    when coalesce(m.has_scheme, false)
      then public.uic('catalogue.scheme_chip','Scheme available')
    else '' end;

  v_card := jsonb_build_object(
    'v', 1,
    'id', m.id,
    'name', coalesce(m.product_name, ''),
    'company', coalesce(m.marketer, ''),
    'image', jsonb_build_object(
      'url', coalesce(v_img, ''),
      'placeholder', v_img is null,
      'placeholder_letter', upper(left(btrim(coalesce(m.product_name, '?')), 1))),
    'pack_line', coalesce(nullif(btrim(coalesce(m.pack_qty, '')), ''),
                          nullif(btrim(coalesce(m.pack_size, '')), ''), ''),
    'unit_word', initcap(coalesce(nullif(btrim(coalesce(m.pack_type, '')), ''),
                                  nullif(btrim(coalesce(m.pack_size, '')), ''), '')),
    'composition', coalesce(nullif(btrim(coalesce(m.salt_composition, '')), ''), ''),
    'has_composition', nullif(btrim(coalesce(m.salt_composition, '')), '') is not null,
    'rx', public.rx_badge(m.rx_required),
    'offer', jsonb_build_object('has', v_offer <> '', 'label', v_offer,
               'tone', jsonb_build_object('name','success','bg','#D1FAE5','fg','#065F46')),
    'availability', jsonb_build_object(
      'is_available', v_avail,
      'label', case when v_avail
                    then coalesce((select value from storefront_ui_label where key='card_avail_in'), '')
                    else coalesce(p_avail->>'cta_short', '') end,
      'tone', case when v_avail
                   then jsonb_build_object('name','success','bg','#D1FAE5','fg','#065F46')
                   else jsonb_build_object('name','neutral',
                          'bg', coalesce(p_avail#>>'{colors,bg}','#F3F4F6'),
                          'fg', coalesce(p_avail#>>'{colors,fg}','#6B7280')) end),
    'price', v_price || jsonb_build_object(
      'has_margin',   coalesce((p_pricing->>'has_margin')::boolean, false),
      'margin_label', coalesce(p_pricing->>'margin_label', ''),
      'margin_chip',  p_pricing->'margin_chip'),
    'qty_in_cart', v_qty,
    'notified', coalesce(p_notified, false),
    'locked', v_locked,
    'cta', public._product_card_cta(v_avail, v_locked, v_qty, p_notified, p_avail->'colors'),
    'wish', public.card_wish(m.id),
    -- CMD #2124 — every word the card's action can move to after a tap.
    'action', public._product_card_action(m, v_qty, p_notified));

  -- CMD #2122 — the ONE line under the price. CMD #2124 — plus the line the
  -- card falls back to once the pack leaves the cart (the pill set to 0).
  return v_card || jsonb_build_object(
    'foot', public._product_card_foot(v_card, v_scheme),
    'foot_idle', public._product_card_foot(v_card || jsonb_build_object('qty_in_cart', 0), v_scheme));
end $function$;
