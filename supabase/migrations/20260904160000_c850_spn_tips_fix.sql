-- CHANGE #850 (fix) — "What moves your SPN" listed all 30 spn_options rows,
-- so the supplier read "10 / Behaviour / 10000 pts": a bare rating as the
-- heading, and 26 lines they were already past or could not use. It now shows
-- the ONE next option per factor that would actually raise the score, gain
-- first. Labels and points are still spn_options verbatim.

insert into ui_copy(key, value) values ('sup_acct.spn_gain', to_jsonb('+{n} pts'::text))
  on conflict (key) do update set value = excluded.value;

CREATE OR REPLACE FUNCTION public.supplier_account_tab_performance()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  sp public.supplier_profiles%rowtype;
  v_this date := date_trunc('month',(now() at time zone 'Asia/Kolkata')::date)::date;
  v_now jsonb; v_trend jsonb; v_factors jsonb; v_tips jsonb;
  v_rank int; v_ret_ok boolean;
begin
  sp := public._sup850_me();
  if sp.id is null then return public._sup850_deny(); end if;

  v_now := public._sup753_metrics(sp.id, v_this);
  insert into public.supplier_perf_monthly (supplier_id, month, metrics, computed_at)
  values (sp.id, v_this, v_now, now())
  on conflict (supplier_id, month) do update
    set metrics = excluded.metrics, computed_at = now();

  v_ret_ok := coalesce((v_now->>'returns_available')::boolean, false);

  select r into v_rank from (
    select x.id, rank() over (order by coalesce(x."SPN",0) desc, lower(x.supplier_name)) r
      from public.supplier_profiles x
     where coalesce(x.is_deleted,false) = false
       and x.zone_id is not distinct from sp.zone_id) q(id, r)
   where q.id = sp.id;

  select coalesce(jsonb_agg(jsonb_build_array(
           jsonb_build_object('text', to_char(m.month,'Mon YY'), 'align','left'),
           jsonb_build_object('text', public._sup753_pct((m.metrics->>'response_rate')::numeric), 'align','right'),
           jsonb_build_object('text', case when m.metrics->>'median_response_s' is null
                                           then public._sup850_t('pf_na')
                                           else public.fmt_duration_short((m.metrics->>'median_response_s')::int) end,
                              'align','right'),
           jsonb_build_object('text', public._sup753_pct((m.metrics->>'fill_rate')::numeric), 'align','right'),
           jsonb_build_object('text', public._sup753_pct((m.metrics->>'short_rate')::numeric), 'align','right'),
           jsonb_build_object('text', public._sup753_pct((m.metrics->>'dispute_rate')::numeric), 'align','right'),
           jsonb_build_object('text', public._sup753_pct((m.metrics->>'on_time_rate')::numeric), 'align','right'))
         order by m.month desc), '[]'::jsonb)
    into v_trend
    from public.supplier_perf_monthly m
   where m.supplier_id = sp.id
     and m.month > (v_this - interval '12 months')::date;

  -- The four factors the SPN is made of, read-only: the supplier sees what he
  -- is graded on and what each grade is worth. Only admin may change them.
  v_factors := jsonb_build_array(
    jsonb_build_array(
      jsonb_build_object('text', public._sup850_t('spn_f_margin'), 'align','left'),
      jsonb_build_object('text', coalesce(nullif(btrim(coalesce(sp.margin,'')),''),
                                          public._sup850_t('not_set')), 'align','left'),
      jsonb_build_object('text', coalesce(sp.margin_points,0)::text, 'align','right')),
    jsonb_build_array(
      jsonb_build_object('text', public._sup850_t('spn_f_cd'), 'align','left'),
      jsonb_build_object('text', coalesce(nullif(btrim(coalesce(sp.cd_condition,'')),''),
                                          public._sup850_t('not_set')), 'align','left'),
      jsonb_build_object('text', coalesce(sp.cd_points,0)::text, 'align','right')),
    jsonb_build_array(
      jsonb_build_object('text', public._sup850_t('spn_f_behaviour'), 'align','left'),
      jsonb_build_object('text', coalesce(nullif(btrim(coalesce(sp.behaviour,'')),''),
                                          public._sup850_t('not_set')), 'align','left'),
      jsonb_build_object('text', coalesce(sp.behaviour_points,0)::text, 'align','right')),
    jsonb_build_array(
      jsonb_build_object('text', public._sup850_t('spn_f_payment'), 'align','left'),
      jsonb_build_object('text', coalesce(nullif(btrim(coalesce(sp.payment_term,'')),''),
                                          public._sup850_t('not_set')), 'align','left'),
      jsonb_build_object('text', coalesce(sp.payment_term_points,0)::text, 'align','right')));

  -- "What moves it" — CHANGE #850 (fix): only the options that would actually
  -- RAISE this supplier's score, cheapest step first, with the factor as the
  -- line and the option as the detail. Listing all 30 rows printed "10 /
  -- Behaviour / 10000 pts" — a bare rating as a heading, and 26 lines the
  -- supplier is already past or cannot use. Labels and points are still
  -- spn_options verbatim; only the choice of WHICH rows and the gain are
  -- computed, and the gain is worded by the backend.
  select coalesce(jsonb_agg(x order by (x->>'_gain')::bigint), '[]'::jsonb)
    into v_tips
    from (
      select distinct on (o.field) jsonb_build_object(
               'title', case o.field
                          when 'margin'       then public._sup850_t('spn_f_margin')
                          when 'cd_condition' then public._sup850_t('spn_f_cd')
                          when 'behaviour'    then public._sup850_t('spn_f_behaviour')
                          when 'payment_term' then public._sup850_t('spn_f_payment')
                          else o.field end,
               'subtitle', o.label,
               'trailing', public.ui_textf('sup_acct.spn_gain',
                             jsonb_build_object('n',
                               to_char(o.points - case o.field
                                 when 'margin'       then coalesce(sp.margin_points,0)
                                 when 'cd_condition' then coalesce(sp.cd_points,0)
                                 when 'behaviour'    then coalesce(sp.behaviour_points,0)
                                 when 'payment_term' then coalesce(sp.payment_term_points,0)
                                 else 0 end, 'FM999,999,999'))),
               'trailing_tone', 'success',
               '_gain', (o.points - case o.field
                           when 'margin'       then coalesce(sp.margin_points,0)
                           when 'cd_condition' then coalesce(sp.cd_points,0)
                           when 'behaviour'    then coalesce(sp.behaviour_points,0)
                           when 'payment_term' then coalesce(sp.payment_term_points,0)
                           else 0 end)::text) as x
        from public.spn_options o
       where o.points > case o.field
               when 'margin'       then coalesce(sp.margin_points,0)
               when 'cd_condition' then coalesce(sp.cd_points,0)
               when 'behaviour'    then coalesce(sp.behaviour_points,0)
               when 'payment_term' then coalesce(sp.payment_term_points,0)
               else 0 end
       -- One step per factor: the next rung, not the whole ladder. DISTINCT ON
       -- keeps the cheapest improving option for each of the four factors, so
       -- the list is at most four lines and every one of them is actionable.
       order by o.field, o.points
    ) t;

  return jsonb_build_object('ok', true, 'blocks', jsonb_build_array(
    jsonb_build_object('kind','tiles','title',public._sup850_t('pf_window'),'tiles', jsonb_build_array(
      jsonb_build_object('label',public._sup850_t('pf_spn'),
        'value', to_char(coalesce(sp."SPN",0),'FM999,999,999'), 'tone','brand'),
      jsonb_build_object('label',public._sup850_t('pf_rank'),
        'value', public.ui_textf('sup_acct.pf_rank_value',
                   jsonb_build_object('n', coalesce(v_rank,0)::text)), 'tone','info'),
      jsonb_build_object('label',public._sup850_t('pf_resp'),
        'value',public._sup753_pct((v_now->>'response_rate')::numeric),'tone','info'),
      jsonb_build_object('label',public._sup850_t('pf_median'),
        'value', case when v_now->>'median_response_s' is null then public._sup850_t('pf_na')
                      else public.fmt_duration_short((v_now->>'median_response_s')::int) end,'tone','neutral'),
      jsonb_build_object('label',public._sup850_t('pf_fill'),
        'value',public._sup753_pct((v_now->>'fill_rate')::numeric),'tone','success'),
      jsonb_build_object('label',public._sup850_t('pf_short'),
        'value',public._sup753_pct((v_now->>'short_rate')::numeric),'tone','warning'),
      jsonb_build_object('label',public._sup850_t('pf_disp'),
        'value',public._sup753_pct((v_now->>'dispute_rate')::numeric),'tone','warning'),
      jsonb_build_object('label',public._sup850_t('pf_ontime'),
        'value',public._sup753_pct((v_now->>'on_time_rate')::numeric),'tone','info'),
      jsonb_build_object('label',public._sup850_t('pf_returns'),
        'value', case when v_ret_ok then public._sup753_pct((v_now->>'returns_rate')::numeric)
                      else public._sup850_t('pf_no_returns') end,
        'tone', case when v_ret_ok then 'neutral' else 'muted' end))),
    jsonb_build_object('kind','table','title',public._sup850_t('spn_title'),
      'columns', jsonb_build_array(
        jsonb_build_object('label',public._sup850_t('spn_c_factor'),'align','left'),
        jsonb_build_object('label',public._sup850_t('spn_c_value'), 'align','left'),
        jsonb_build_object('label',public._sup850_t('spn_c_points'),'align','right')),
      'rows', v_factors),
    jsonb_build_object('kind','list','title',public._sup850_t('spn_moves'),
      'empty', public._sup850_t('spn_moves_empty'), 'items', v_tips),
    jsonb_build_object('kind','table','title',public._sup850_t('pf_trend'),
      'columns', jsonb_build_array(
        jsonb_build_object('label',public._sup850_t('pf_month'), 'align','left'),
        jsonb_build_object('label',public._sup850_t('pf_resp'),  'align','right'),
        jsonb_build_object('label',public._sup850_t('pf_median'),'align','right'),
        jsonb_build_object('label',public._sup850_t('pf_fill'),  'align','right'),
        jsonb_build_object('label',public._sup850_t('pf_short'), 'align','right'),
        jsonb_build_object('label',public._sup850_t('pf_disp'),  'align','right'),
        jsonb_build_object('label',public._sup850_t('pf_ontime'),'align','right')),
      'rows', v_trend)));
end $function$;
