-- CMD #1826 — Om amendment 3 (6 Sep 2026, final): the second price row is
-- captioned "Sale price" and its VALUE is the literal "PTR" when no
-- pricing_ready amount exists. No "On quote", no note sentence, no dash,
-- no zero, no blank, no MRP repeated. Copy is an UPDATE, never a deploy;
-- the function defaults follow the same wording and the on-quote note now
-- defaults to '' so an empty label row yields has_note:false.
update public.storefront_ui_label set value = 'Sale price' where key = 'pdp_sale_price_caption';
update public.storefront_ui_label set value = 'PTR'        where key = 'pdp_sale_on_quote';
update public.storefront_ui_label set value = ''           where key = 'pdp_sale_on_quote_note';

create or replace function public.pdp_price_lines(p_product_id bigint, p_mrp numeric)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_has_mrp boolean := (p_mrp is not null and p_mrp > 0);
  v_entitled boolean := public.viewer_sees_trade_price();
  v_ready boolean := false;
  v_pb jsonb;
  v_mrp_cap text := public._pdp_label('mrp_caption', 'MRP');
  v_mrp_val text; v_mrp_note text := public._pdp_label('pdp_mrp_ceiling_note', 'Printed pack ceiling — not the selling price');
  v_sale_cap text := public._pdp_label('pdp_sale_price_caption', 'Sale price');
  v_sale_val text; v_sale_note text := ''; v_sale_amount boolean := false; v_sale_tone text := 'secondary';
  v_side text := '';
  v_sticky_main text;
begin
  v_mrp_val := case when v_has_mrp then public.inr_money(p_mrp)
                    else public._pdp_label('pdp_mrp_missing', 'Not printed on this pack') end;

  select mp.pricing_ready and coalesce(mp.ptr, 0) > 0
    into v_ready
    from public.medicine_pricing mp where mp.product_id = p_product_id;
  v_ready := coalesce(v_ready, false);

  if v_ready and v_entitled then
    -- The SAME block every card reads, already gated on entitlement and
    -- formatted with inr_money. Net (PTR + GST − discount) is what is paid.
    v_pb := public.storefront_pricing(p_mrp, null::numeric, p_product_id);
    if coalesce((v_pb->>'has_net')::boolean, false) then
      v_sale_val := v_pb->>'net_display';
      v_sale_amount := true; v_sale_tone := 'primary';
      v_sale_note := replace(replace(public._pdp_label('pdp_sale_ptr_note', 'PTR {ptr} · {gst}'),
                         '{ptr}', coalesce(v_pb->>'ptr_display', '')),
                         '{gst}', coalesce(v_pb#>>'{gst,pct_display}', ''));
      v_sale_note := btrim(regexp_replace(v_sale_note, '\s·\s*$', ''));
    end if;
  end if;

  if not v_sale_amount then
    if v_ready and not v_entitled then
      v_sale_val := public._pdp_label('ptr_locked_note', 'Register and get approved to see trade prices');
      v_sticky_main := public._pdp_label('pdp_sticky_locked', 'Trade price on approval');
    else
      v_sale_val := public._pdp_label('pdp_sale_on_quote', 'PTR');
      v_sale_note := public._pdp_label('pdp_sale_on_quote_note', '');
    end if;
  end if;

  if v_has_mrp then
    v_side := btrim(public._pdp_label('pdp_sticky_mrp_prefix', 'MRP') || ' ' || public.inr_money(p_mrp));
  end if;

  return jsonb_build_object(
    'has', true,
    'mrp', jsonb_build_object(
      'caption',    v_mrp_cap,
      'value',      v_mrp_val,
      'has_amount', v_has_mrp,
      'has_note',   v_has_mrp,
      'note',       case when v_has_mrp then v_mrp_note else '' end,
      'tone',       'secondary'),
    'sale', jsonb_build_object(
      'caption',    v_sale_cap,
      'value',      v_sale_val,
      'has_amount', v_sale_amount,
      'has_note',   v_sale_note <> '',
      'note',       v_sale_note,
      'tone',       v_sale_tone),
    'sticky', jsonb_build_object(
      'main',         coalesce(v_sticky_main, v_sale_val),
      'main_caption', public._pdp_label('pdp_sticky_sale_caption', 'Sale price'),
      'main_tone',    v_sale_tone,
      'has_side',     v_side <> '',
      'side',         v_side));
end $$;

revoke all on function public.pdp_price_lines(bigint, numeric) from public, anon, authenticated;
