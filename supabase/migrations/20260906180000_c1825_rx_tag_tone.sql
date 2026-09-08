-- CMD #1825 — rx_badge() is a CLASSIFICATION, not a warning.
--
-- Om's decision, 6 Sep 2026: the product page shows Rx or OTC only. mediBO is
-- B2B — every buyer is a licence-verified pharmacy, chemist, clinic or
-- hospital, approved before it can order — so a full-width red "your drug
-- licence must be on file" box on EVERY Schedule H pack was a warning aimed at
-- nobody. It trained people to ignore red.
--
-- Shape is unchanged: {has, is_rx, label, title, note, tone{bg,fg}}. Every
-- caller (product_detail, _cat_cards, _sf_cards, the compact card's chip)
-- keeps reading exactly the keys it read before. Only the Rx TONE changes:
-- the danger red (#FEE2E2/#991B1B) becomes the design system's soft-info
-- tint (#EFF6FF/#1E40AF). OTC keeps its soft green. Title and note stay in
-- ui_copy for any surface that still wants them; the PDP stops rendering them.
--
-- The licence gate is NOT touched: rx_licence_state(), rx_licence_gate() and
-- every rx.licence_* copy key are exactly as before. Idempotent — replays
-- cleanly on live.

insert into public.ui_copy(key, value) values
  ('rx.badge_rx',        to_jsonb('Rx'::text)),
  ('rx.badge_otc',       to_jsonb('OTC'::text)),
  ('rx.pdp_rx_title',    to_jsonb('Prescription medicine'::text)),
  ('rx.pdp_rx_note',     to_jsonb('Schedule H / H1 stock. Your pharmacy drug licence must be on file to order this.'::text)),
  ('rx.pdp_otc_title',   to_jsonb('Over the counter'::text)),
  ('rx.pdp_otc_note',    to_jsonb('No prescription needed for this pack.'::text))
on conflict (key) do nothing;

create or replace function public.rx_badge(p_rx text)
returns jsonb
language sql
stable
set search_path to 'public'
as $function$
  select case when upper(btrim(coalesce(p_rx,''))) = 'RX' then
    jsonb_build_object(
      'has', true, 'is_rx', true,
      'label', public._c('rx.badge_rx'),
      'title', public._c('rx.pdp_rx_title'),
      'note',  public._c('rx.pdp_rx_note'),
      'tone',  jsonb_build_object('bg','#EFF6FF','fg','#1E40AF'))
  when upper(btrim(coalesce(p_rx,''))) = 'OTC' then
    jsonb_build_object(
      'has', true, 'is_rx', false,
      'label', public._c('rx.badge_otc'),
      'title', public._c('rx.pdp_otc_title'),
      'note',  public._c('rx.pdp_otc_note'),
      'tone',  jsonb_build_object('bg','#D1FAE5','fg','#065F46'))
  else jsonb_build_object('has', false, 'is_rx', false) end;
$function$;

comment on function public.rx_badge(text) is
  'CMD #1825: the Rx/OTC class as a quiet tag {has,is_rx,label,title,note,tone}. Rx is soft-info, OTC soft-green — never danger red. Not a licence warning; that is rx_licence_state()/rx_licence_gate().';

grant execute on function public.rx_badge(text) to authenticated, anon;
