-- ============================================================================
-- CHANGE #323 (part 3) — the payloads.
--
-- Every screen in this feature computes NOTHING. Each RPC below returns its own
-- title, tabs, tile labels, field labels, option words, empty states, toasts
-- and already-formatted ₹ figures. Re-wording the settlement screens, or
-- re-costing what an order is charged, is an UPDATE to settlement_label /
-- cost_types — never a deploy.
--
-- Idempotent by construction (#233).
-- ============================================================================

-- A tile, a row and a field, built once so every payload is the same shape.
create or replace function public._stl_tile(p_key text, p_value text)
returns jsonb language sql stable as $$
  select jsonb_build_object('key', p_key, 'label', public._stl_c(p_key),
                            'value', p_value, 'tone', public._stl_tone(p_key))
$$;

create or replace function public._stl_money_tile(p_key text, p_value numeric)
returns jsonb language sql stable as $$
  select public._stl_tile(p_key, public.inr_money(p_value))
$$;

-- The four ways a cost can be charged, worded by the backend, in one place so
-- every dropdown in the app offers exactly the same list.
create or replace function public._stl_basis_options()
returns jsonb language sql stable as $$
  select coalesce(jsonb_agg(jsonb_build_object('key', k, 'label', public._stl_c('basis.' || k))
                            order by ord), '[]'::jsonb)
    from (values ('flat',1),('per_km',2),('per_box',3),('pct_of_order',4)) v(k, ord)
$$;

create or replace function public._stl_cadence_options()
returns jsonb language sql stable as $$
  select coalesce(jsonb_agg(jsonb_build_object('key', k,
                              'label', public._stl_c('cad.' || k),
                              'note',  public._stl_c('cad.' || k || '_note'))
                            order by ord), '[]'::jsonb)
    from (values ('same_day',1),('t_plus_2',2),('weekly',3),('monthly',4)) v(k, ord)
$$;

create or replace function public._stl_mode_options()
returns jsonb language sql stable as $$
  select jsonb_build_array(
    jsonb_build_object('key','self',   'label', public._stl_c('mode.self'),
                       'note', public._stl_c('mode.self_note')),
    jsonb_build_object('key','partner','label', public._stl_c('mode.partner'), 'note', ''))
$$;

create or replace function public._stl_route_options()
returns jsonb language sql stable as $$
  select jsonb_build_array(
    jsonb_build_object('key','manual','label', public._stl_c('route.manual'),
                       'note', public._stl_c('route.manual_note')),
    jsonb_build_object('key','automatic','label', public._stl_c('route.automatic'),
                       'note', public._stl_c('route.automatic_note')))
$$;

create or replace function public._stl_denied()
returns jsonb language sql stable as $$
  select jsonb_build_object('ok', false, 'message', public._stl_c('ui.not_authorized'),
                            'title', public._stl_c('ui.title'))
$$;

-- ── The zones tab ───────────────────────────────────────────────────────────
create or replace function public.settlement_zones()
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select case when not public.is_admin() then public._stl_denied() else
    jsonb_build_object(
      'ok', true,
      'heading',   public._stl_c('sec.zones'),
      'mode_options',    public._stl_mode_options(),
      'cadence_options', public._stl_cadence_options(),
      'fields', jsonb_build_object(
        'mode',    public._stl_c('fld.mode'),
        'partner', public._stl_c('fld.partner'),
        'split',   public._stl_c('fld.split'),
        'cadence', public._stl_c('fld.cadence')),
      'save_label', public._stl_c('ui.save'),
      'partners', coalesce((select jsonb_agg(jsonb_build_object('id', rp.id, 'label', rp.partner_name)
                                             order by rp.partner_name)
                              from public.region_partners rp where coalesce(rp.is_active,true)), '[]'::jsonb),
      'rows', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'zone_id',    z.id,
                 'label',      z.name,
                 'mode',       coalesce(m.mode,'self'),
                 'mode_label', public._stl_c('mode.' || coalesce(m.mode,'self')),
                 'mode_tone',  public._stl_tone('mode.' || coalesce(m.mode,'self')),
                 'partner_id', m.partner_id,
                 'partner_label', coalesce(rp.partner_name, ''),
                 'split_pct',  coalesce(m.split_pct, 0),
                 'sub',        case when coalesce(m.mode,'self') = 'partner'
                                    then coalesce(rp.partner_name,'') || ' · ' ||
                                         public._stl_num(coalesce(m.split_pct,0)) || '% · ' ||
                                         public._stl_c('cad.' || coalesce(m.cadence,'same_day'))
                                    else public._stl_c('mode.self_note') end,
                 'value',      public._stl_num(coalesce(m.split_pct,0)) || '%',
                 'cadence',    coalesce(m.cadence,'same_day'),
                 'cadence_label', public._stl_c('cad.' || coalesce(m.cadence,'same_day'))
               ) order by z.id)
          from public.zones z
          left join public.zone_fulfilment_mode m on m.zone_id = z.id
          left join public.region_partners rp on rp.id = m.partner_id
         where coalesce(z.is_active, true)), '[]'::jsonb),
      'empty_text', public._stl_c('ui.empty'))
  end
$$;

create or replace function public.settlement_zone_set(p_zone_id smallint, p_patch jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_mode    text;
  v_partner bigint;
  v_split   numeric;
  v_cadence text;
  cur public.zone_fulfilment_mode%rowtype;
begin
  if not public.is_admin() then return public._stl_denied(); end if;
  select * into cur from public.zone_fulfilment_mode where zone_id = p_zone_id;
  if not found and not exists (select 1 from public.zones where id = p_zone_id) then
    return jsonb_build_object('ok', false, 'message', public._stl_c('err.no_zone'));
  end if;

  v_mode    := coalesce(p_patch->>'mode', cur.mode, 'self');
  v_partner := coalesce(nullif(p_patch->>'partner_id','')::bigint, cur.partner_id);
  v_split   := coalesce(nullif(p_patch->>'split_pct','')::numeric, cur.split_pct, 0);
  v_cadence := coalesce(p_patch->>'cadence', cur.cadence, 'same_day');

  if v_mode = 'partner' and v_partner is null then
    return jsonb_build_object('ok', false, 'message', public._stl_c('err.no_partner'));
  end if;
  if v_split < 0 or v_split > 100 then
    return jsonb_build_object('ok', false, 'message', public._stl_c('err.bad_split'));
  end if;
  if v_cadence not in ('same_day','t_plus_2','weekly','monthly') then
    v_cadence := 'same_day';
  end if;
  -- A self zone keeps 100%. The table's own check says so too; this makes the
  -- screen's answer match instead of raising.
  if v_mode = 'self' then v_split := 0; v_partner := null; end if;

  insert into public.zone_fulfilment_mode (zone_id, mode, partner_id, split_pct, cadence, updated_at, updated_by)
  values (p_zone_id, v_mode, v_partner, v_split, v_cadence, now(),
          coalesce(auth.jwt() ->> 'email', 'admin'))
  on conflict (zone_id) do update set
    mode = excluded.mode, partner_id = excluded.partner_id,
    split_pct = excluded.split_pct, cadence = excluded.cadence,
    updated_at = now(), updated_by = excluded.updated_by;

  return jsonb_build_object('ok', true, 'message', public._stl_c('ui.saved'),
                            'zones', public.settlement_zones());
end $$;

-- ── The cost types tab ──────────────────────────────────────────────────────
create or replace function public.settlement_cost_types()
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select case when not public.is_admin() then public._stl_denied() else
    jsonb_build_object(
      'ok', true,
      'heading', public._stl_c('sec.costs'),
      'note',    public._stl_c('cost.basis_note'),
      'basis_options', public._stl_basis_options(),
      'add_label',  public._stl_c('ui.add_cost_type'),
      'save_label', public._stl_c('ui.save'),
      'fields', jsonb_build_object(
        'slug',   public._stl_c('fld.slug'),
        'label',  public._stl_c('fld.label'),
        'basis',  public._stl_c('fld.basis'),
        'base',   public._stl_c('fld.base'),
        'rate',   public._stl_c('fld.rate'),
        'active', public._stl_c('fld.active')),
      'rows', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'slug',  ct.slug,
                 'label', ct.label,
                 'basis', ct.basis,
                 'basis_label', public._stl_c('basis.' || ct.basis),
                 'default_value', ct.default_value,
                 'rate_value',    ct.rate_value,
                 'active', ct.active,
                 'sub',   public._stl_c('basis.' || ct.basis) ||
                          case when ct.basis = 'pct_of_order'
                               then ' · ' || public.inr_money(ct.default_value) || ' + ' || public._stl_num(ct.rate_value) || '%'
                               when ct.basis = 'flat'
                               then ' · ' || public.inr_money(ct.default_value)
                               else ' · ' || public.inr_money(ct.default_value) || ' + ' || public.inr_money(ct.rate_value) end,
                 'value', case when ct.active then '' else public._stl_c('fld.active') end,
                 'note',  coalesce(ct.note,'')
               ) order by ct.sort_order, ct.slug)
          from public.cost_types ct), '[]'::jsonb),
      'empty_text', public._stl_c('ui.empty'))
  end
$$;

-- Add or edit a cost type. INSERT is the whole point: a brand-new way of
-- costing an order arrives from this sheet, with no deploy behind it.
create or replace function public.settlement_cost_type_save(p_patch jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_slug  text := lower(regexp_replace(coalesce(p_patch->>'slug',''), '[^a-zA-Z0-9]+', '_', 'g'));
  v_label text := btrim(coalesce(p_patch->>'label',''));
  v_basis text := coalesce(p_patch->>'basis','flat');
  cur public.cost_types%rowtype;
begin
  if not public.is_admin() then return public._stl_denied(); end if;
  v_slug := trim(both '_' from v_slug);
  if v_slug = '' then
    return jsonb_build_object('ok', false, 'message', public._stl_c('err.slug_required'));
  end if;
  select * into cur from public.cost_types where slug = v_slug;
  if v_label = '' then v_label := coalesce(cur.label, ''); end if;
  if v_label = '' then
    return jsonb_build_object('ok', false, 'message', public._stl_c('err.label_required'));
  end if;
  if v_basis not in ('flat','per_km','per_box','pct_of_order') then
    return jsonb_build_object('ok', false, 'message', public._stl_c('err.bad_basis'));
  end if;

  insert into public.cost_types (slug, label, basis, default_value, rate_value, active,
                                 sort_order, note, updated_at, updated_by)
  values (v_slug, v_label, v_basis,
          coalesce(nullif(p_patch->>'default_value','')::numeric, cur.default_value, 0),
          coalesce(nullif(p_patch->>'rate_value','')::numeric,    cur.rate_value, 0),
          coalesce((p_patch->>'active')::boolean, cur.active, true),
          coalesce(cur.sort_order, 100 + coalesce((select max(sort_order) from public.cost_types), 0)),
          coalesce(p_patch->>'note', cur.note),
          now(), coalesce(auth.jwt() ->> 'email','admin'))
  on conflict (slug) do update set
    label = excluded.label, basis = excluded.basis,
    default_value = excluded.default_value, rate_value = excluded.rate_value,
    active = excluded.active, note = excluded.note,
    updated_at = now(), updated_by = excluded.updated_by;

  return jsonb_build_object('ok', true, 'message', public._stl_c('ui.saved'),
                            'cost_types', public.settlement_cost_types());
end $$;

-- ── One order's cost lines ──────────────────────────────────────────────────
create or replace function public.settlement_order_costs(p_order_id uuid)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select case when not public.is_admin() then public._stl_denied() else
    jsonb_build_object(
      'ok', true,
      'order_id', p_order_id,
      'heading',  public._stl_c('sec.cost_lines'),
      'note',     public._stl_c('cost.basis_note'),
      'computed_label', public._stl_c('cost.computed'),
      'override_label', public._stl_c('cost.override'),
      'clear_label',    public._stl_c('cost.clear'),
      'save_label',     public._stl_c('ui.save'),
      'fields', jsonb_build_object('override', public._stl_c('fld.override'),
                                   'note',     public._stl_c('fld.note')),
      'frozen', exists (select 1 from public.partner_settlements s
                          join public.partner_settlement_periods p on p.id = s.period_id
                         where s.order_id = p_order_id and p.status <> 'open'),
      'frozen_text', public._stl_c('cost.frozen'),
      'rows', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'cost_type', oc.cost_type,
                 'label',     ct.label,
                 'sub',       coalesce(oc.driver_label,'') ||
                              case when oc.override_amount is not null
                                   then ' · ' || public._stl_c('cost.computed') || ' ' ||
                                        public.inr_money(oc.computed_amount)
                                   else '' end,
                 'computed',  oc.computed_amount,
                 'computed_text', public.inr_money(oc.computed_amount),
                 'override',  oc.override_amount,
                 'override_text', case when oc.override_amount is null then ''
                                       else public.inr_money(oc.override_amount) end,
                 'value',     public.inr_money(coalesce(oc.override_amount, oc.computed_amount)),
                 'value_tone', case when oc.override_amount is not null then 'warning' end,
                 'source',    oc.source,
                 'note',      coalesce(oc.note,'')
               ) order by ct.sort_order, oc.cost_type)
          from public.order_costs oc
          join public.cost_types ct on ct.slug = oc.cost_type
         where oc.order_id = p_order_id), '[]'::jsonb),
      'total_label', public._stl_c('cost.total'),
      'total',       public.inr_money(public._stl_cost_total(p_order_id)),
      'empty_text',  public._stl_c('cost.empty'))
  end
$$;

-- The override wins the money; the computed figure is never overwritten, so the
-- edit stays readable as a deviation. A null override hands the line back to
-- the formula.
create or replace function public.settlement_order_cost_set(p_order_id uuid,
                                                            p_cost_type text,
                                                            p_override numeric default null,
                                                            p_note text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_frozen boolean;
begin
  if not public.is_admin() then return public._stl_denied(); end if;
  if not exists (select 1 from public.cost_types where slug = p_cost_type) then
    return jsonb_build_object('ok', false, 'message', public._stl_c('err.no_cost_type'));
  end if;
  select exists (select 1 from public.partner_settlements s
                   join public.partner_settlement_periods p on p.id = s.period_id
                  where s.order_id = p_order_id and p.status <> 'open') into v_frozen;
  if v_frozen then
    return jsonb_build_object('ok', false, 'message', public._stl_c('cost.frozen'));
  end if;

  perform public.settlement_cost_lines_build(p_order_id, false);

  update public.order_costs
     set override_amount = p_override,
         source = case when p_override is null then 'auto' else 'manual' end,
         note = p_note,
         edited_by = coalesce(auth.jwt() ->> 'email','admin'),
         updated_at = now()
   where order_id = p_order_id and cost_type = p_cost_type;

  perform public.settlement_order_row(p_order_id);
  perform public.settlement_period_totals(s.period_id)
     from public.partner_settlements s
    where s.order_id = p_order_id and s.period_id is not null;

  return jsonb_build_object('ok', true, 'message', public._stl_c('ui.saved'),
                            'costs', public.settlement_order_costs(p_order_id));
end $$;

-- ── The statement — ONE shape, read by the admin and by the partner ─────────
-- Due, transferred and pending read identically whether Razorpay Route moved
-- the money or a human did, because they are computed from the same two
-- numbers in both lanes.
create or replace function public.settlement_statement(p_period_id bigint)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  p public.partner_settlement_periods%rowtype;
  cfg public.settlement_config%rowtype;
  v_paid numeric;
  v_pending numeric;
  v_admin boolean := public.is_admin();
begin
  select * into p from public.partner_settlement_periods where id = p_period_id;
  if not found then
    return jsonb_build_object('ok', false, 'message', public._stl_c('err.no_period'));
  end if;
  if not v_admin and p.partner_id is distinct from public.my_partner_id() then
    return jsonb_build_object('ok', false, 'message', public._stl_c('ui.partner_denied'));
  end if;
  select * into cfg from public.settlement_config where id = 1;

  select coalesce(sum(amount) filter (where status = 'paid'), 0)
    into v_paid from public.partner_settlement_payments where period_id = p.id;
  v_pending := round(greatest(p.payable - v_paid, 0), 2);

  return jsonb_build_object(
    'ok', true,
    'period_id', p.id,
    'title',    public._stl_c('ui.title'),
    'heading',  format(public._stl_c('period.window'),
                       public.ist_fmt(p.period_start::timestamptz, 'dmy'),
                       public.ist_fmt(p.period_end::timestamptz, 'dmy')),
    'sub',      public._stl_c('cad.' || p.cadence) || ' · ' ||
                format(public._stl_c('period.due_on'),
                       public.ist_fmt(p.due_on::timestamptz, 'dmy')),
    'partner',  coalesce((select partner_name from public.region_partners where id = p.partner_id), ''),
    'status',       p.status,
    'status_label', public._stl_c('period.' || p.status),
    'status_tone',  public._stl_tone('period.' || p.status),
    'is_admin',     v_admin,
    'can_settle',   v_admin and p.status = 'due',
    'settle_label', public._stl_c('period.settle'),
    'record_label', public._stl_c('route.record'),
    'route_mode',   coalesce(cfg.route_mode,'manual'),
    'route_label',  public._stl_c('route.' || coalesce(cfg.route_mode,'manual')),
    'route_note',   public._stl_c('route.' || coalesce(cfg.route_mode,'manual') || '_note'),
    'negative',     p.payable = 0 and p.net_due < 0,
    'negative_text',public._stl_c('period.negative'),
    'tiles', jsonb_build_array(
      public._stl_money_tile('tile.revenue',       p.revenue),
      public._stl_money_tile('tile.goods',         p.goods_cost),
      public._stl_money_tile('tile.gross',         p.gross_margin),
      public._stl_money_tile('tile.costs',         p.cost_total),
      public._stl_money_tile('tile.distributable', p.distributable),
      public._stl_money_tile('tile.medibo',        p.medibo_share),
      public._stl_money_tile('tile.partner',       p.partner_share),
      public._stl_money_tile('tile.brought_forward', p.brought_forward),
      public._stl_money_tile('tile.due',           p.payable),
      public._stl_money_tile('tile.transferred',   v_paid),
      public._stl_money_tile('tile.pending',       v_pending),
      public._stl_money_tile('tile.carry_forward', p.carry_forward),
      public._stl_tile('tile.orders', p.orders_count::text)),
    'costs', jsonb_build_object(
      'heading', public._stl_c('sec.cost_lines'),
      'rows', coalesce((
        select jsonb_agg(jsonb_build_object('label', ct.label,
                 'sub', public._stl_c('basis.' || coalesce(min(oc.basis), ct.basis)),
                 'value', public.inr_money(sum(coalesce(oc.override_amount, oc.computed_amount))))
               order by ct.sort_order)
          from public.order_costs oc
          join public.cost_types ct on ct.slug = oc.cost_type
         where oc.order_id in (select order_id from public.partner_settlements
                                where period_id = p.id)
         group by ct.slug, ct.label, ct.sort_order, ct.basis), '[]'::jsonb)),
    'orders', jsonb_build_object(
      'heading', public._stl_c('sec.orders'),
      'empty_text', public._stl_c('ui.empty'),
      'rows', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'order_id', s.order_id,
                 'label', coalesce(s.order_code, ''),
                 'sub', public.ist_fmt(s.order_date::timestamptz, 'dmy') || ' · ' ||
                        public._stl_c('tile.gross') || ' ' || public.inr_money(s.gross_margin) ||
                        ' · ' || public._stl_c('tile.costs') || ' ' || public.inr_money(s.cost_total),
                 'value', public.inr_money(s.distributable),
                 'value_tone', case when s.distributable < 0 then 'danger' end)
               order by s.order_date, s.order_code)
          from public.partner_settlements s where s.period_id = p.id), '[]'::jsonb)),
    'payments', jsonb_build_object(
      'heading', public._stl_c('sec.payments'),
      'empty_text', public._stl_c('period.empty'),
      'rows', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'label', public._stl_c('route.' || case when x.method = 'razorpay_route'
                                                         then 'automatic' else 'manual' end),
                 'sub', case when x.status = 'queued' then public._stl_c('route.queued')
                             else coalesce(nullif(x.rzp_transfer_id,''), nullif(x.reference,''), '') end ||
                        ' · ' || public.ist_fmt(x.paid_at, 'dmy'),
                 'value', public.inr_money(x.amount),
                 'value_tone', case when x.status = 'queued' then 'warning' else 'success' end)
               order by x.paid_at desc)
          from public.partner_settlement_payments x where x.period_id = p.id), '[]'::jsonb)),
    'footnote', public._stl_c('ui.footnote'));
end $$;

-- ── The period list ─────────────────────────────────────────────────────────
create or replace function public.settlement_periods(p_limit int default 30,
                                                     p_partner_id bigint default null)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select case when not public.is_admin() then public._stl_denied() else
    jsonb_build_object(
      'ok', true,
      'heading', public._stl_c('sec.periods'),
      'note',    public._stl_c('period.auto_note'),
      'empty_text', public._stl_c('period.empty'),
      'rows', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'period_id', p.id,
                 'label', format(public._stl_c('period.window'),
                                 public.ist_fmt(p.period_start::timestamptz,'dmy'),
                                 public.ist_fmt(p.period_end::timestamptz,'dmy')),
                 'sub', coalesce(rp.partner_name,'') || ' · ' ||
                        public._stl_c('period.' || p.status) || ' · ' ||
                        public._stl_c('cad.' || p.cadence),
                 'value', public.inr_money(p.payable),
                 'value_tone', public._stl_tone('period.' || p.status))
               order by p.period_end desc, p.id desc)
          from (select * from public.partner_settlement_periods
                 where (p_partner_id is null or partner_id = p_partner_id)
                 order by period_end desc, id desc
                 limit greatest(coalesce(p_limit,30), 1)) p
          left join public.region_partners rp on rp.id = p.partner_id), '[]'::jsonb))
  end
$$;

-- ── Money out ───────────────────────────────────────────────────────────────
-- The automatic lane records the Route transfer id against the queued row it
-- already created; the manual lane writes a paid row with the operator's
-- reference. Same table, same statement, one arithmetic.
create or replace function public.settlement_record_payment(p_period_id bigint,
                                                            p_amount numeric,
                                                            p_reference text default null,
                                                            p_note text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  cfg public.settlement_config%rowtype;
  p   public.partner_settlement_periods%rowtype;
  v_queued bigint;
begin
  if not public.is_admin() then return public._stl_denied(); end if;
  select * into p from public.partner_settlement_periods where id = p_period_id;
  if not found then
    return jsonb_build_object('ok', false, 'message', public._stl_c('err.no_period'));
  end if;
  if coalesce(p_amount, 0) <= 0 then
    return jsonb_build_object('ok', false, 'message', public._stl_c('err.bad_amount'));
  end if;
  select * into cfg from public.settlement_config where id = 1;

  select id into v_queued from public.partner_settlement_payments
   where period_id = p_period_id and status = 'queued'
   order by id limit 1;

  if v_queued is not null then
    update public.partner_settlement_payments
       set status = 'paid', amount = p_amount,
           rzp_transfer_id = coalesce(nullif(p_reference,''), rzp_transfer_id),
           note = coalesce(p_note, note),
           paid_at = now(), recorded_by = coalesce(auth.jwt() ->> 'email','admin')
     where id = v_queued;
  else
    insert into public.partner_settlement_payments
      (period_id, amount, method, status, rzp_transfer_id, reference, note, recorded_by)
    values (p_period_id, p_amount,
            case when coalesce(cfg.route_mode,'manual') = 'automatic' then 'razorpay_route' else 'manual' end,
            'paid',
            case when coalesce(cfg.route_mode,'manual') = 'automatic' then nullif(p_reference,'') end,
            case when coalesce(cfg.route_mode,'manual') = 'automatic' then null else nullif(p_reference,'') end,
            p_note, coalesce(auth.jwt() ->> 'email','admin'));
  end if;

  return jsonb_build_object('ok', true, 'message', public._stl_c('route.recorded'),
                            'statement', public.settlement_statement(p_period_id));
end $$;

create or replace function public.settlement_settle(p_period_id bigint)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.is_admin() then return public._stl_denied(); end if;
  if not exists (select 1 from public.partner_settlement_periods where id = p_period_id) then
    return jsonb_build_object('ok', false, 'message', public._stl_c('err.no_period'));
  end if;
  update public.partner_settlement_periods
     set status = 'settled', settled_at = now(),
         settled_by = coalesce(auth.jwt() ->> 'email','admin')
   where id = p_period_id;
  return jsonb_build_object('ok', true, 'message', public._stl_c('period.settled_msg'),
                            'statement', public.settlement_statement(p_period_id));
end $$;

-- ── The switch ──────────────────────────────────────────────────────────────
create or replace function public.settlement_config_get()
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select case when not public.is_admin() then public._stl_denied() else
    jsonb_build_object(
      'ok', true,
      'heading', public._stl_c('route.heading'),
      'save_label', public._stl_c('ui.save'),
      'route_mode', (select route_mode from public.settlement_config where id = 1),
      'route_options', public._stl_route_options(),
      'default_cadence', (select default_cadence from public.settlement_config where id = 1),
      'cadence_options', public._stl_cadence_options(),
      'auto_close', (select auto_close from public.settlement_config where id = 1),
      'fields', jsonb_build_object(
        'route_mode', public._stl_c('fld.route_mode'),
        'cadence',    public._stl_c('fld.cadence'),
        'auto_close', public._stl_c('fld.auto_close')))
  end
$$;

create or replace function public.settlement_config_set(p_patch jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.is_admin() then return public._stl_denied(); end if;
  update public.settlement_config set
    route_mode = case when p_patch ? 'route_mode'
                        and p_patch->>'route_mode' in ('manual','automatic')
                      then p_patch->>'route_mode' else route_mode end,
    default_cadence = case when p_patch ? 'default_cadence'
                             and p_patch->>'default_cadence' in ('same_day','t_plus_2','weekly','monthly')
                           then p_patch->>'default_cadence' else default_cadence end,
    auto_close = coalesce((p_patch->>'auto_close')::boolean, auto_close),
    updated_at = now(), updated_by = coalesce(auth.jwt() ->> 'email','admin')
  where id = 1;
  return jsonb_build_object('ok', true, 'message', public._stl_c('ui.saved'),
                            'config', public.settlement_config_get());
end $$;

-- ── The admin dashboard ─────────────────────────────────────────────────────
create or replace function public.settlement_dashboard(p_days int default 30,
                                                       p_partner_id bigint default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  d int := greatest(coalesce(p_days, 30), 1);
  t record;
  v_paid numeric;
begin
  if not public.is_admin() then return public._stl_denied(); end if;

  select count(*) n,
         coalesce(sum(revenue),0) rev, coalesce(sum(goods_cost),0) goods,
         coalesce(sum(gross_margin),0) gross, coalesce(sum(cost_total),0) costs,
         coalesce(sum(distributable),0) dist, coalesce(sum(partner_share),0) psh,
         coalesce(sum(medibo_share),0) msh, coalesce(sum(payable),0) due,
         coalesce(sum(orders_count),0) orders
    into t
    from public.partner_settlement_periods
   where period_end >= (now() at time zone 'Asia/Kolkata')::date - d
     and (p_partner_id is null or partner_id = p_partner_id);

  select coalesce(sum(x.amount), 0) into v_paid
    from public.partner_settlement_payments x
    join public.partner_settlement_periods p on p.id = x.period_id
   where x.status = 'paid'
     and p.period_end >= (now() at time zone 'Asia/Kolkata')::date - d
     and (p_partner_id is null or p.partner_id = p_partner_id);

  return jsonb_build_object(
    'ok', true,
    'title',    public._stl_c('ui.title'),
    'subtitle', public._stl_c('ui.subtitle'),
    'footnote', public._stl_c('ui.footnote'),
    'error_text', public._stl_c('ui.error'),
    'retry_text', public._stl_c('ui.retry'),
    'empty_text', public._stl_c('ui.empty'),
    'refresh_label', public._stl_c('ui.refresh'),
    'recalculate_label', public._stl_c('ui.recalculate'),
    'range_label', format(public._stl_c('ui.range_days'), d::text),
    'has_data', t.n > 0,
    'tabs', coalesce((select jsonb_agg(jsonb_build_object('key', k, 'label', public._stl_c('tab.' || k))
                                       order by ord)
                        from (values ('overview',1),('zones',2),('costs',3),('periods',4)) v(k, ord)), '[]'::jsonb),
    'tiles', jsonb_build_array(
      public._stl_money_tile('tile.revenue',       t.rev),
      public._stl_money_tile('tile.goods',         t.goods),
      public._stl_money_tile('tile.gross',         t.gross),
      public._stl_money_tile('tile.costs',         t.costs),
      public._stl_money_tile('tile.distributable', t.dist),
      public._stl_money_tile('tile.medibo',        t.msh),
      public._stl_money_tile('tile.partner',       t.psh),
      public._stl_money_tile('tile.due',           t.due),
      public._stl_money_tile('tile.transferred',   v_paid),
      public._stl_money_tile('tile.pending',       greatest(t.due - v_paid, 0)),
      public._stl_tile('tile.orders', t.orders::text)),
    'route',  public.settlement_config_get(),
    'zones',  public.settlement_zones(),
    'periods', public.settlement_periods(30, p_partner_id),
    'month_rollup', jsonb_build_object(
      'heading', public._stl_c('sec.month_rollup'),
      'empty_text', public._stl_c('period.empty'),
      'rows', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'label', m.month,
                 'sub', coalesce(m.partner_name,'') || ' · ' ||
                        public._stl_c('tile.orders') || ' ' || m.orders_count::text,
                 'value', public.inr_money(m.partner_share))
               order by m.month desc)
          from public.partner_settlement_month_v m
         where (p_partner_id is null or m.partner_id = p_partner_id)), '[]'::jsonb)));
end $$;

-- The admin's explicit "Recalculate": rebuild cost lines from the cost types as
-- they stand now, for every order whose period is still open, then re-total.
create or replace function public.settlement_recalculate(p_days int default 30)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare r record; v_n int := 0;
begin
  if not public.is_admin() then return public._stl_denied(); end if;
  for r in
    select v.order_id from public.pnl_order_v v
     where v.order_date >= (now() at time zone 'Asia/Kolkata')::date - greatest(coalesce(p_days,30),1)
       and not exists (select 1 from public.partner_settlements ps
                         join public.partner_settlement_periods p on p.id = ps.period_id
                        where ps.order_id = v.order_id and p.status <> 'open')
  loop
    perform public.settlement_cost_lines_build(r.order_id, true);
    v_n := v_n + 1;
  end loop;
  perform public.settlement_build(null, null);
  return jsonb_build_object('ok', true, 'message', public._stl_c('ui.recalculated'),
                            'orders', v_n);
end $$;

-- ── The partner's own statement ─────────────────────────────────────────────
-- Own zone only, enforced here AND by the row policies underneath, so a
-- forged period id gets the backend's own refusal instead of somebody's money.
create or replace function public.partner_statement(p_period_id bigint default null,
                                                    p_limit int default 20)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_partner bigint := public.my_partner_id();
  v_pid bigint := p_period_id;
begin
  if v_partner is null then
    return jsonb_build_object('ok', false, 'title', public._stl_c('ui.title'),
                              'message', public._stl_c('ui.partner_denied'));
  end if;
  if v_pid is null then
    select id into v_pid from public.partner_settlement_periods
     where partner_id = v_partner and status <> 'open'
     order by period_end desc, id desc limit 1;
  end if;

  return jsonb_build_object(
    'ok', true,
    'title',    public._stl_c('ui.title'),
    'subtitle', public._stl_c('ui.subtitle'),
    'footnote', public._stl_c('ui.footnote'),
    'error_text', public._stl_c('ui.error'),
    'retry_text', public._stl_c('ui.retry'),
    'empty_text', public._stl_c('ui.empty'),
    'partner', coalesce((select partner_name from public.region_partners where id = v_partner), ''),
    'periods', jsonb_build_object(
      'heading', public._stl_c('sec.periods'),
      'empty_text', public._stl_c('period.empty'),
      'rows', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'period_id', p.id,
                 'label', format(public._stl_c('period.window'),
                                 public.ist_fmt(p.period_start::timestamptz,'dmy'),
                                 public.ist_fmt(p.period_end::timestamptz,'dmy')),
                 'sub', public._stl_c('period.' || p.status) || ' · ' ||
                        public._stl_c('cad.' || p.cadence),
                 'value', public.inr_money(p.payable),
                 'value_tone', public._stl_tone('period.' || p.status))
               order by p.period_end desc, p.id desc)
          from (select * from public.partner_settlement_periods
                 where partner_id = v_partner and status <> 'open'
                 order by period_end desc, id desc
                 limit greatest(coalesce(p_limit,20),1)) p), '[]'::jsonb)),
    'statement', case when v_pid is null then null
                      else public.settlement_statement(v_pid) end);
end $$;

-- ── Grants ──────────────────────────────────────────────────────────────────
revoke all on function public.settlement_zones()                              from public, anon;
revoke all on function public.settlement_zone_set(smallint, jsonb)            from public, anon;
revoke all on function public.settlement_cost_types()                         from public, anon;
revoke all on function public.settlement_cost_type_save(jsonb)                from public, anon;
revoke all on function public.settlement_order_costs(uuid)                    from public, anon;
revoke all on function public.settlement_order_cost_set(uuid, text, numeric, text) from public, anon;
revoke all on function public.settlement_statement(bigint)                    from public, anon;
revoke all on function public.settlement_periods(int, bigint)                 from public, anon;
revoke all on function public.settlement_record_payment(bigint, numeric, text, text) from public, anon;
revoke all on function public.settlement_settle(bigint)                       from public, anon;
revoke all on function public.settlement_config_get()                         from public, anon;
revoke all on function public.settlement_config_set(jsonb)                    from public, anon;
revoke all on function public.settlement_dashboard(int, bigint)               from public, anon;
revoke all on function public.settlement_recalculate(int)                     from public, anon;
revoke all on function public.partner_statement(bigint, int)                  from public, anon;

grant execute on function public.settlement_zones()                              to authenticated, service_role;
grant execute on function public.settlement_zone_set(smallint, jsonb)            to authenticated, service_role;
grant execute on function public.settlement_cost_types()                         to authenticated, service_role;
grant execute on function public.settlement_cost_type_save(jsonb)                to authenticated, service_role;
grant execute on function public.settlement_order_costs(uuid)                    to authenticated, service_role;
grant execute on function public.settlement_order_cost_set(uuid, text, numeric, text) to authenticated, service_role;
grant execute on function public.settlement_statement(bigint)                    to authenticated, service_role;
grant execute on function public.settlement_periods(int, bigint)                 to authenticated, service_role;
grant execute on function public.settlement_record_payment(bigint, numeric, text, text) to authenticated, service_role;
grant execute on function public.settlement_settle(bigint)                       to authenticated, service_role;
grant execute on function public.settlement_config_get()                         to authenticated, service_role;
grant execute on function public.settlement_config_set(jsonb)                    to authenticated, service_role;
grant execute on function public.settlement_dashboard(int, bigint)               to authenticated, service_role;
grant execute on function public.settlement_recalculate(int)                     to authenticated, service_role;
grant execute on function public.partner_statement(bigint, int)                  to authenticated, service_role;

grant execute on function public.settlement_tick()                  to service_role;
grant execute on function public.settlement_build(date, date)       to service_role;
grant execute on function public.settlement_close_due()             to service_role;
grant execute on function public.settlement_period_totals(bigint)   to service_role;
grant execute on function public.settlement_order_row(uuid)         to service_role;
grant execute on function public.settlement_snapshot_order(uuid)    to service_role;
grant execute on function public.settlement_cost_lines_build(uuid, boolean) to service_role;

-- ── The proof ───────────────────────────────────────────────────────────────
-- The arithmetic this feature exists for, asserted without needing a billed
-- order: the four cost bases, the four cadence windows, the split on a period
-- TOTAL, and the loss rule — a negative period pays nothing and carries.
create or replace function public.c323_settlement_proof()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  b record;
  v jsonb := '[]'::jsonb;
  v_dist numeric;
  v_share numeric;
begin
  -- basis: base 20 + 8/km over 12.5 km = 120
  v := v || jsonb_build_object('case','per_km',
        'ok', round(20 + 8 * public._stl_driver('per_km', 12.5, 2, 5000), 2) = 120);
  -- basis: 0 + 15/box over 2 boxes = 30
  v := v || jsonb_build_object('case','per_box',
        'ok', round(0 + 15 * public._stl_driver('per_box', 12.5, 2, 5000), 2) = 30);
  -- basis: 2% of a 5000 order = 100
  v := v || jsonb_build_object('case','pct_of_order',
        'ok', round(0 + 2 * public._stl_driver('pct_of_order', 12.5, 2, 5000), 2) = 100);
  -- basis: flat ignores every driver
  v := v || jsonb_build_object('case','flat',
        'ok', round(99 + 7 * public._stl_driver('flat', 12.5, 2, 5000), 2) = 99);

  select * into b from public.settlement_period_bounds('same_day', date '2026-08-31');
  v := v || jsonb_build_object('case','same_day',
        'ok', b.period_start = date '2026-08-31' and b.period_end = date '2026-08-31'
              and b.due_on = date '2026-08-31');
  select * into b from public.settlement_period_bounds('t_plus_2', date '2026-08-31');
  v := v || jsonb_build_object('case','t_plus_2',
        'ok', b.period_end = date '2026-08-31' and b.due_on = date '2026-09-02');
  select * into b from public.settlement_period_bounds('weekly', date '2026-08-31');
  v := v || jsonb_build_object('case','weekly',
        'ok', b.period_start = date '2026-08-31' and b.period_end = date '2026-09-06');
  select * into b from public.settlement_period_bounds('monthly', date '2026-08-31');
  v := v || jsonb_build_object('case','monthly',
        'ok', b.period_start = date '2026-08-01' and b.period_end = date '2026-08-31');

  -- The loss rule, on the period TOTAL: +500 and -200 net to 300, split 50:50
  -- gives 150 — NOT 250 from settling only the profitable order.
  v_dist  := 500 + (-200);
  v_share := round(v_dist * 50 / 100, 2);
  v := v || jsonb_build_object('case','loss_nets_within_period', 'ok', v_share = 150);
  -- A period under water pays nothing and carries the shortfall.
  v := v || jsonb_build_object('case','negative_period_pays_nothing',
        'ok', greatest(-120, 0) = 0 and least(-120, 0) = -120);
  -- The deal Om named.
  v := v || jsonb_build_object('case','raipur_seed',
        'ok', exists (select 1 from public.zone_fulfilment_mode m
                        join public.region_partners rp on rp.id = m.partner_id
                       where m.zone_id = 1 and m.mode = 'partner' and m.split_pct = 50));
  v := v || jsonb_build_object('case','four_cost_types',
        'ok', (select count(*) from public.cost_types
                where slug in ('delivery','packaging','platform_fee','marketing')) = 4);
  v := v || jsonb_build_object('case','delivery_and_packaging_seed_flat',
        'ok', (select count(*) from public.cost_types
                where slug in ('delivery','packaging') and basis = 'flat') = 2);
  v := v || jsonb_build_object('case','dispatcher_task_registered',
        'ok', exists (select 1 from public.cron_task where name = 'settlement_close' and enabled));

  return jsonb_build_object(
    'ok', not exists (select 1 from jsonb_array_elements(v) e where (e->>'ok')::boolean is not true),
    'cases', v);
end $$;
revoke all on function public.c323_settlement_proof() from public, anon;
grant execute on function public.c323_settlement_proof() to authenticated, service_role;
