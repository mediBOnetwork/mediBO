-- CHANGE #309 — admin_delivery_ops(): ONE payload for the whole operations
-- screen. Five sections in one round trip rather than five RPCs, because the
-- screen is opened on a phone on a warehouse floor and each extra call is
-- another chance to half-load.
--
-- Every heading, empty state and button word is a ui_copy string resolved HERE,
-- so the screen contains no display literal at all.
create or replace function public.admin_delivery_ops(p_zone smallint default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_zone smallint; v_cfg jsonb;
  v_payouts jsonb; v_service jsonb; v_docs jsonb; v_claims jsonb; v_ratings jsonb;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('allowed', false);
  end if;
  v_zone := public.scope_zone(p_zone);
  v_cfg  := public._dcfg(v_zone);

  -- (4) payout periods, newest first
  select coalesce(jsonb_agg(jsonb_build_object(
      'period_id', pp.id,
      'partner_name', coalesce(r.full_name,''),
      'partner_id', pp.partner_id,
      'period_label', to_char(pp.period_start,'DD Mon') || ' – ' || to_char(pp.period_end,'DD Mon YYYY'),
      'drop_count', pp.drop_count,
      'drop_count_label', pp.drop_count || ' drop' || case when pp.drop_count = 1 then '' else 's' end,
      'amount_label', public.inr_money(pp.net_amount),
      'status', pp.status,
      'status_chip', case when pp.status='paid' then public._c('admin.delivery.payout_paid_chip')
                          else public._c('admin.delivery.payout_unpaid_chip') end,
      'status_colors', case when pp.status='paid'
                            then jsonb_build_object('bg','#D1FAE5','fg','#065F46')
                            else jsonb_build_object('bg','#FEF3C7','fg','#92400E') end,
      'can_pay', (pp.status = 'unpaid'),
      -- the button's word travels with the row, so the screen never has to
      -- hunt for a label in a sibling section
      'pay_label', public._c('admin.delivery.payout_pay_btn'),
      'paid_ref', coalesce(pp.paid_ref,'')
    ) order by pp.created_at desc), '[]'::jsonb)
    into v_payouts
  from public.delivery_payout_periods pp
  join public.delivery_partner_registrations r on r.id = pp.partner_id
  where public.scope_zone_ok(r.zone_id, v_zone)
  limit 50;

  -- (5) serviceability rows
  select coalesce(jsonb_agg(jsonb_build_object(
      'pincode', sv.pincode,
      'mode', sv.mode,
      'mode_label', case sv.mode when 'serviceable' then 'Serviceable'
                                 when 'warn' then 'Warn'
                                 else 'Blocked' end,
      'mode_colors', case sv.mode
          when 'serviceable' then jsonb_build_object('bg','#D1FAE5','fg','#065F46')
          when 'warn'        then jsonb_build_object('bg','#FEF3C7','fg','#92400E')
          else                    jsonb_build_object('bg','#FEE2E2','fg','#991B1B') end,
      'note', coalesce(sv.note,''),
      'zone_id', sv.zone_id
    ) order by sv.pincode), '[]'::jsonb)
    into v_service
  from public.delivery_serviceability sv
  where sv.is_active;

  -- (6) riders whose papers need attention, worst first
  select coalesce(jsonb_agg(d.state order by (d.state->>'expired_count')::int desc,
                                            (d.state->>'expiring_count')::int desc), '[]'::jsonb)
    into v_docs
  from (
    select public.delivery_doc_state(r.id) state
      from public.delivery_partner_registrations r
     where r.is_active and coalesce(r.is_deleted,false) = false
       and public.scope_zone_ok(r.zone_id, v_zone)
  ) d
  where (d.state->>'expired_count')::int > 0 or (d.state->>'expiring_count')::int > 0;

  -- (8) open doorstep claims
  select coalesce(jsonb_agg(jsonb_build_object(
      'claim_id', c.id,
      'order_code', coalesce(o.order_code,''),
      'pharmacy', coalesce(o.pharmacy_name,''),
      'kind_label', case c.kind
                      when 'damaged' then public._c('delivery.claim_kind_damaged')
                      when 'short'   then public._c('delivery.claim_kind_short')
                      else                public._c('delivery.claim_kind_missing') end,
      'qty_label', trim_scale(c.qty)::text,
      'amount_label', case when c.amount is null then '—' else public.inr_money(c.amount) end,
      'note', coalesce(c.note,''),
      'photo_path', c.photo_path,
      'raised_label', to_char(c.raised_at at time zone 'Asia/Kolkata','DD Mon, hh12:MI am'),
      'approve_label', public._c('admin.delivery.claim_approve_btn'),
      'reject_label',  public._c('admin.delivery.claim_reject_btn')
    ) order by c.raised_at desc), '[]'::jsonb)
    into v_claims
  from public.delivery_claims c
  join public.orders o on o.id = c.order_id
  where c.status = 'open'
    and public.scope_zone_ok(o.zone_id, v_zone);

  -- (7) most recent ratings, so a bad one is visible the same day
  select coalesce(jsonb_agg(jsonb_build_object(
      'stars', dr.stars,
      'stars_label', repeat('★', dr.stars) || repeat('☆', 5 - dr.stars),
      'partner_name', coalesce(r.full_name,''),
      'comment', coalesce(dr.comment,''),
      'when_label', to_char(dr.created_at at time zone 'Asia/Kolkata','DD Mon, hh12:MI am'),
      'is_poor', (dr.stars <= coalesce((v_cfg->>'rating_poor_at_or_below')::int, 2))
    ) order by dr.created_at desc), '[]'::jsonb)
    into v_ratings
  from public.delivery_ratings dr
  left join public.delivery_partner_registrations r on r.id = dr.partner_id
  where dr.created_at > now() - interval '30 days'
  limit 50;

  return jsonb_build_object(
    'allowed', true,
    'zone_id', v_zone,
    'title',    public._c('admin.delivery.ops_title'),
    'subtitle', public._c('admin.delivery.ops_subtitle'),
    'config', v_cfg,
    'sections', jsonb_build_array(
      jsonb_build_object('key','payouts', 'title', public._c('admin.delivery.payout_title'),
        'empty', public._c('admin.delivery.payout_empty'),
        'add_label', public._c('admin.delivery.payout_open_btn'), 'rows', v_payouts),
      jsonb_build_object('key','claims', 'title', public._c('admin.delivery.claims_title'),
        'empty', public._c('admin.delivery.claims_empty'), 'rows', v_claims),
      jsonb_build_object('key','service', 'title', public._c('admin.delivery.service_title'),
        'empty', public._c('admin.delivery.service_empty'),
        'add_label', public._c('admin.delivery.service_add_btn'), 'rows', v_service),
      jsonb_build_object('key','docs', 'title', public._c('admin.delivery.docs_title'),
        'empty', public._c('admin.delivery.docs_empty'), 'rows', v_docs),
      jsonb_build_object('key','ratings', 'title', public._c('admin.delivery.rating_col'),
        'empty', public._c('admin.delivery.rating_none'), 'rows', v_ratings)),
    'error_label', public._c('admin.delivery.ops_error'),
    'retry_label', public._c('admin.delivery.ops_retry'),
    -- the partner list the "open a payout period" picker needs
    'partners', coalesce((
      select jsonb_agg(jsonb_build_object('partner_id', r.id, 'name', coalesce(r.full_name,''))
             order by r.full_name)
        from public.delivery_partner_registrations r
       where r.is_active and coalesce(r.is_deleted,false)=false
         and public.scope_zone_ok(r.zone_id, v_zone)), '[]'::jsonb));
end $function$;

grant execute on function public.admin_delivery_ops(smallint) to authenticated;
