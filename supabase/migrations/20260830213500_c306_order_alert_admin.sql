-- ============================================================================
-- CHANGE #306 — the admin surface's backend. One RPC per screen section, every
-- label included, so the screen decides nothing.
-- ============================================================================

-- Existing pending orders predate the alert engine. They belong in the badge —
-- nothing should be silently lost — but they must never ring at 2am for an
-- order placed weeks ago, and they must never be auto-cancelled: ring=false,
-- expires_at=null does exactly that.
insert into public.order_alert
  (order_id, order_code, customer_id, customer_name, amount, risk, state, stage,
   credit_blocked, credit_note, expires_at, ring, created_at)
select o.id,
       coalesce(o.order_code, o.payment_id, ''),
       o.customer_id,
       coalesce(nullif(btrim(pp.pharmacy_name),''), nullif(btrim(o.pharmacy_name),''), ''),
       coalesce(o.total_amount,0),
       'unpaid', 'ringing', 'new',
       coalesce((public.customer_credit_state(o.customer_id)->>'blocked')::boolean, false),
       nullif(public.customer_credit_state(o.customer_id)->>'message',''),
       null, false, o.created_at
  from public.orders o
  left join public.pharmacy_profiles pp on pp.id = o.customer_id
 where o.status = 'pending' and o.closed_at is null
   and not public.order_is_paid(o.id)
on conflict (order_id) do nothing;

-- ── Settings + everything the screen draws ──────────────────────────────────
create or replace function public.order_alert_settings()
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare cfg public.order_alert_config; v_phone text; v_open jsonb; v_log jsonb;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_admin');
  end if;
  cfg := public._oa_cfg();
  v_phone := coalesce((select value #>> '{}' from public.app_settings
                        where key='admin_wa_phone'), '');

  select coalesce(jsonb_agg(public._oa_item(a) order by a.created_at desc), '[]'::jsonb)
    into v_open
    from public.order_alert a where a.state = 'ringing';

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', l.id,
           'order_code', coalesce((select o.order_code from public.orders o where o.id = l.order_id),''),
           'supplier', coalesce(l.supplier_name,''),
           'allowed', l.allowed,
           'reason', coalesce(l.reason,''),
           'reason_label', public.oa_label(coalesce(l.detail->>'reason', l.reason)),
           'when_label', public._oa_age_label(l.created_at)) order by l.created_at desc), '[]'::jsonb)
    into v_log
    from (select * from public.purchase_gate_log order by created_at desc limit 30) l;

  return jsonb_build_object(
    'ok', true,
    'title',    public.oa_label('settings_title'),
    'subtitle', public.oa_label('settings_subtitle'),
    'sections', jsonb_build_object(
       'timings', public.oa_label('section_timings'),
       'credit',  public.oa_label('section_credit'),
       'open',    public.oa_label('section_open'),
       'log',     public.oa_label('section_log')),
    'fields', jsonb_build_array(
      jsonb_build_object('key','enabled','label',public.oa_label('field_enabled'),
                         'type','bool','value',cfg.enabled),
      jsonb_build_object('key','ring_delay_s','label',public.oa_label('field_ring_delay'),
                         'type','int','value',cfg.ring_delay_s),
      jsonb_build_object('key','rering_after_s','label',public.oa_label('field_rering'),
                         'type','int','value',cfg.rering_after_s),
      jsonb_build_object('key','wa_after_s','label',public.oa_label('field_wa'),
                         'type','int','value',cfg.wa_after_s),
      jsonb_build_object('key','critical_after_s','label',public.oa_label('field_critical'),
                         'type','int','value',cfg.critical_after_s),
      jsonb_build_object('key','ring_seconds','label',public.oa_label('field_ring_seconds'),
                         'type','int','value',cfg.ring_seconds),
      jsonb_build_object('key','autocancel_after_min','label',public.oa_label('field_autocancel'),
                         'type','int','value',cfg.autocancel_after_min),
      jsonb_build_object('key','admin_wa_phone','label',public.oa_label('escalation_phone_label'),
                         'type','text','value',v_phone,
                         'hint',public.oa_label('escalation_phone_hint')),
      jsonb_build_object('key','new_customer_prepaid_only','label',public.oa_label('field_prepaid_new'),
                         'type','bool','value',cfg.new_customer_prepaid_only),
      jsonb_build_object('key','established_credit_limit','label',public.oa_label('field_established_limit'),
                         'type','money','value',cfg.established_credit_limit,
                         'display',public.inr_money(cfg.established_credit_limit)),
      jsonb_build_object('key','established_min_paid_orders','label',public.oa_label('field_min_paid'),
                         'type','int','value',cfg.established_min_paid_orders),
      jsonb_build_object('key','enforce_credit_block','label',public.oa_label('field_enforce'),
                         'type','bool','value',cfg.enforce_credit_block),
      jsonb_build_object('key','purchase_gate_enabled','label',public.oa_label('field_gate'),
                         'type','bool','value',cfg.purchase_gate_enabled)),
    'phone_warning', case when v_phone = '' then public.oa_label('escalation_phone_missing') else '' end,
    'saved_label',   public.oa_label('saved'),
    'override_label',public.oa_label('override_label'),
    'override_hint', public.oa_label('override_hint'),
    'credit_limit_label',   public.oa_label('credit_limit_label'),
    'credit_prepaid_label', public.oa_label('credit_prepaid_label'),
    'empty_title',   public.oa_label('empty_title'),
    'empty_body',    public.oa_label('empty_body'),
    'open_count',    public.order_alert_open_count(),
    'open',          v_open,
    'log',           v_log);
end $$;

create or replace function public.order_alert_settings_set(p_patch jsonb)
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_label text; k text;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_admin');
  end if;
  select lower(btrim(u.email)) into v_label from auth.users u where u.id = auth.uid();

  for k in select jsonb_object_keys(coalesce(p_patch,'{}'::jsonb)) loop
    if k = 'admin_wa_phone' then
      insert into public.app_settings(key, value)
      values ('admin_wa_phone', to_jsonb(right(regexp_replace(coalesce(p_patch->>k,''),'\D','','g'),10)))
      on conflict (key) do update set value = excluded.value;
    elsif k in ('enabled','new_customer_prepaid_only','enforce_credit_block',
                'block_at_placement','purchase_gate_enabled') then
      execute format('update public.order_alert_config set %I = $1, updated_at=now(), updated_by=$2 where id=''singleton''', k)
        using (p_patch->>k)::boolean, coalesce(v_label,'admin');
    elsif k in ('rering_after_s','wa_after_s','critical_after_s','autocancel_after_min',
                'ring_seconds','ring_delay_s','established_min_paid_orders') then
      execute format('update public.order_alert_config set %I = greatest($1,0), updated_at=now(), updated_by=$2 where id=''singleton''', k)
        using (p_patch->>k)::int, coalesce(v_label,'admin');
    elsif k = 'established_credit_limit' then
      update public.order_alert_config
         set established_credit_limit = greatest((p_patch->>k)::numeric, 0),
             updated_at = now(), updated_by = coalesce(v_label,'admin')
       where id = 'singleton';
    elsif k = 'labels' then
      update public.order_alert_config
         set labels = coalesce(labels,'{}'::jsonb) || (p_patch->'labels'),
             updated_at = now(), updated_by = coalesce(v_label,'admin')
       where id = 'singleton';
    end if;
  end loop;

  return public.order_alert_settings() || jsonb_build_object('saved', true);
end $$;

-- ── Per-customer credit ─────────────────────────────────────────────────────
create or replace function public.customer_credit_list(p_q text default null, p_limit integer default 30)
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare v jsonb;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_admin');
  end if;
  select coalesce(jsonb_agg(x order by (x->>'outstanding')::numeric desc), '[]'::jsonb) into v
  from (
    select public.customer_credit_state(pp.id)
           || jsonb_build_object('customer_id', pp.id,
                                 'customer_name', coalesce(nullif(btrim(pp.pharmacy_name),''),
                                                           nullif(btrim(pp.customer_name),''), '')) as x
      from public.pharmacy_profiles pp
     where coalesce(pp.is_deleted,false) = false
       and (p_q is null or btrim(p_q) = ''
            or pp.pharmacy_name ilike '%'||p_q||'%'
            or pp.customer_name ilike '%'||p_q||'%')
       and exists (select 1 from public.orders o where o.customer_id = pp.id)
     limit greatest(coalesce(p_limit,30),1)
  ) s;
  return jsonb_build_object('ok', true, 'items', v);
end $$;

create or replace function public.customer_credit_set(
  p_customer_id uuid, p_limit numeric, p_prepaid_only boolean, p_note text default null)
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_label text;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_admin');
  end if;
  select lower(btrim(u.email)) into v_label from auth.users u where u.id = auth.uid();
  insert into public.customer_credit (customer_id, credit_limit, prepaid_only, note,
                                      updated_at, updated_by)
  values (p_customer_id, greatest(coalesce(p_limit,0),0), coalesce(p_prepaid_only,false),
          nullif(btrim(coalesce(p_note,'')),''), now(), coalesce(v_label,'admin'))
  on conflict (customer_id) do update
     set credit_limit = excluded.credit_limit,
         prepaid_only = excluded.prepaid_only,
         note         = excluded.note,
         updated_at   = now(),
         updated_by   = excluded.updated_by;
  return jsonb_build_object('ok', true, 'state', public.customer_credit_state(p_customer_id),
                            'message', public.oa_label('saved'));
end $$;

-- ── Fix, same command: outstanding must ignore orders that ARE paid ─────────
-- An order accepted by verify_and_accept_payment carries a verified claim, but
-- one credited by the Razorpay webhook is 'accepted' with no claim row — so
-- total minus claims counted the whole order as outstanding and every
-- established customer read as over limit on the first call. order_is_paid()
-- is the authority on paid; a paid order owes nothing.
create or replace function public.customer_credit_state(p_customer_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare
  cfg public.order_alert_config; cc public.customer_credit;
  v_out numeric := 0; v_paid_orders int := 0;
  v_limit numeric; v_prepaid boolean; v_blocked boolean; v_name text;
begin
  cfg := public._oa_cfg();
  if p_customer_id is null then
    return jsonb_build_object('ok', false, 'known', false, 'blocked', false,
                              'outstanding', 0, 'limit', 0);
  end if;

  select * into cc from public.customer_credit where customer_id = p_customer_id;
  select coalesce(pp.pharmacy_name, pp.customer_name, '') into v_name
    from public.pharmacy_profiles pp where pp.id = p_customer_id;

  select coalesce(sum(greatest(o.total_amount - public.order_paid_amount(o.id), 0)), 0)
    into v_out
    from public.orders o
   where o.customer_id = p_customer_id
     and o.status not in ('cancelled','rejected')
     and o.closed_at is null
     and not public.order_is_paid(o.id);

  select count(*) into v_paid_orders
    from public.orders o
   where o.customer_id = p_customer_id and public.order_is_paid(o.id);

  if cc.customer_id is not null then
    v_limit   := cc.credit_limit;
    v_prepaid := cc.prepaid_only;
  elsif v_paid_orders >= greatest(cfg.established_min_paid_orders, 1) then
    v_limit   := cfg.established_credit_limit;
    v_prepaid := false;
  else
    v_limit   := 0;
    v_prepaid := cfg.new_customer_prepaid_only;
  end if;

  v_blocked := cfg.enforce_credit_block and (v_prepaid or v_out > v_limit);

  return jsonb_build_object(
    'ok', true,
    'known', cc.customer_id is not null,
    'customer_id', p_customer_id,
    'customer_name', coalesce(v_name,''),
    'prepaid_only', v_prepaid,
    'limit', v_limit,
    'limit_display', public.inr_money(v_limit),
    'outstanding', v_out,
    'outstanding_display', public.inr_money(v_out),
    'paid_orders', v_paid_orders,
    'blocked', v_blocked,
    'reason', case when not cfg.enforce_credit_block then 'enforcement_off'
                   when v_prepaid then 'prepaid_only'
                   when v_out > v_limit then 'over_limit'
                   else 'within_limit' end,
    'message', case
      when not cfg.enforce_credit_block then ''
      when v_prepaid then public.oa_label('credit_prepaid_only',
             jsonb_build_object('customer', coalesce(v_name,''),
                                'outstanding', public.inr_money(v_out)))
      when v_out > v_limit then public.oa_label('credit_over_limit',
             jsonb_build_object('customer', coalesce(v_name,''),
                                'outstanding', public.inr_money(v_out),
                                'limit', public.inr_money(v_limit)))
      else '' end);
end $$;

-- The backfilled rows carried the inflated block; recompute them now.
update public.order_alert a
   set credit_blocked = coalesce((public.customer_credit_state(a.customer_id)->>'blocked')::boolean,false),
       credit_note    = nullif(public.customer_credit_state(a.customer_id)->>'message','')
 where a.state = 'ringing';
