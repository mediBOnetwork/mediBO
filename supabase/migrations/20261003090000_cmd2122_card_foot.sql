-- CMD #2122 — the universal grid card's foot line.
--
-- The approved design (image A, "Universal product card") puts exactly ONE
-- line under the price row, and which line it is depends on the card's state:
-- unavailable → the backend's unavailable word (danger), notified → the
-- "we'll tell you" sentence (muted), in cart → "{n} in cart" (brand), price
-- locked → the lock note (muted), a scheme running → its effective-rate line
-- (brand), a trade margin → the margin line (brand), otherwise the
-- availability label (success). That choice is a decision, so it lives here:
-- `card.foot = {has, label, tone{name,bg,fg}}` and the Flutter card prints it.
--
-- Customer surfaces scope to the viewer's own zone (as #2121 documents);
-- admin_active_zone/date is the staff picker and does not apply to a card.
-- Idempotent: CREATE OR REPLACE / ON CONFLICT DO NOTHING only.

insert into public.storefront_ui_label(key, value, note) values
  ('card_foot_unavailable', 'Unavailable right now', 'CMD #2122 card foot when the product cannot be added'),
  ('card_foot_notified',    'We''ll notify you when it''s back', 'CMD #2122 card foot once the viewer asked to be notified'),
  ('card_foot_locked',      'Log in to see your rate', 'CMD #2122 card foot when the trade price is locked')
on conflict (key) do nothing;

create or replace function public._product_card_foot(p_card jsonb, p_scheme_line text default '')
returns jsonb language sql stable security definer set search_path to 'public' as $$
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
        jsonb_build_object('label', coalesce(p_card#>>'{cta,label}', ''),
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
$$;

create or replace function public._product_card(
  m public."MEDICINE", p_pricing jsonb, p_avail jsonb, p_qty integer, p_notified boolean)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_img   text := nullif(btrim(coalesce(m.image_url_1, '')), '');
  v_avail boolean := coalesce((p_avail->>'is_available')::boolean, false);
  v_price jsonb := coalesce(p_pricing->'card_price', '{}'::jsonb);
  v_locked boolean := coalesce((v_price->>'price_locked')::boolean, true)
                      and not public.viewer_is_approved_customer();
  v_qty   int := greatest(coalesce(p_qty, 0), 0);
  v_offer text;
  v_card  jsonb;
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
    'wish', public.card_wish(m.id));

  -- CMD #2122 — the ONE line under the price, chosen here so the card never
  -- picks between availability, cart, lock, scheme and margin in Dart.
  return v_card || jsonb_build_object('foot',
    public._product_card_foot(v_card, coalesce(p_pricing#>>'{scheme_effective,label}', '')));
end $$;

-- The catalogue's out-of-zone rewrite keeps the foot honest too.
create or replace function public._product_card_unavailable(p_card jsonb, p_label text)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select case when p_card is null then null else
    (select c || jsonb_build_object('foot', public._product_card_foot(c, ''))
       from (select p_card || jsonb_build_object(
               'availability', jsonb_build_object('is_available', false, 'label', coalesce(p_label, ''),
                 'tone', jsonb_build_object('name','neutral','bg','#F3F4F6','fg','#6B7280')),
               'cta', public._product_card_cta(false, false, 0, coalesce((p_card->>'notified')::boolean, false))) as c) x)
  end;
$$;

revoke all on function public._product_card_foot(jsonb, text) from public, anon;
grant execute on function public._product_card_foot(jsonb, text) to authenticated, service_role;
