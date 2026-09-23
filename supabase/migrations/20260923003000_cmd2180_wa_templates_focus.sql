-- CMD #2180 — ?focus=<template> pins one template to the top of the admin list.
--
-- The WhatsApp templates screen paints 86 rows in the payload's own order. On a
-- 360px phone the eighteenth row (customer_account_notice, the UTILITY template
-- the customer_imported route now sends) sits far below the fold, so nothing —
-- a person or a browser journey — reaches it without a long scroll.
--
-- wa_templates_screen now takes an optional template name and sorts that row
-- first. The zero-argument function is dropped first: a defaulted argument
-- alongside it would be an ambiguous overload for PostgREST.
--
-- Idempotent: drop-if-exists + create-or-replace + re-grant.

drop function if exists public.wa_templates_screen();

CREATE OR REPLACE FUNCTION public.wa_templates_screen(p_focus text default null)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'mode', 'public'
AS $function$
declare v_rows jsonb; v_edit_limit int := 10; v_ts jsonb; v_copy jsonb;
begin
  if role_for_medibo_only() not in ('admin','super_admin') then return jsonb_build_object('error','not_authorized'); end if;

  select coalesce(jsonb_agg(x order by x->>'sort_key'), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      -- CMD #2180: a named template is pinned to the top of the payload. '!'
      -- sorts before every status bucket, so ?focus=<name> puts that one row
      -- first and the rest keep the order they always had.
      'sort_key', case when p_focus is not null and t.name = p_focus then '!'
                       else case t.status when 'REJECTED' then '0' when 'PENDING' then '1'
                                          when 'DRAFT' then '2' else '3' end end
                  || to_char(t.updated_at,'YYYYMMDDHH24MISS'),
      'id', t.id, 'meta_id', t.meta_id,
      'can_preview', true,
      'preview_label', 'See how it reaches the customer',
      'can_edit', t.status <> 'PENDING',
      'edit_blocked_reason', case when t.status = 'PENDING'
        then 'Meta is reviewing this wording — you can still preview it' end, 'name', t.name, 'language', t.language,
      'category', t.category, 'category_label', initcap(lower(t.category)),
      'status', t.status,
      'status_label', case t.status
          when 'DRAFT' then 'Draft' when 'PENDING' then 'Pending review'
          when 'APPROVED' then 'Approved' when 'REJECTED' then 'Rejected'
          when 'PAUSED' then 'Paused by Meta' when 'DISABLED' then 'Disabled' else initcap(lower(t.status)) end,
      'status_tone', case t.status
          when 'APPROVED' then 'green' when 'REJECTED' then 'red' when 'DISABLED' then 'red'
          when 'PAUSED' then 'yellow' when 'PENDING' then 'yellow' else 'grey' end,
      'components', t.components,
      'token_map', t.token_map,
      'preview', public.wa_template_preview(t.components, null),
      'body_preview', (select c->>'text' from jsonb_array_elements(t.components) c where upper(c->>'type')='BODY' limit 1),
      'rejected_reason', nullif(t.rejected_reason,'NONE'),
      'rejection_help', case when t.status = 'REJECTED' then public.wa_rejection_help(t.rejected_reason) end,
      'quality_score', t.quality_score,
      'quality_tone', case upper(coalesce(t.quality_score,'')) when 'GREEN' then 'green'
                        when 'YELLOW' then 'yellow' when 'RED' then 'red' else 'grey' end,
      'category_changed', (t.submitted_category is not null and t.submitted_category <> t.category),
      'category_change_note', case when t.submitted_category is not null and t.submitted_category <> t.category
          then format('Meta moved this from %s to %s — cost per message changes',
                      initcap(lower(t.submitted_category)), initcap(lower(t.category))) end,
      'edits_used', (select count(*) from wa_template_versions v
                     where v.template_id = t.id and v.action='edit'
                       and v.submitted_at >= date_trunc('month', now())),
      'edits_limit', v_edit_limit,
      'edits_label', format('%s of %s edits used this month',
                     (select count(*) from wa_template_versions v
                      where v.template_id = t.id and v.action='edit'
                        and v.submitted_at >= date_trunc('month', now())), v_edit_limit),
      'versions', (select coalesce(jsonb_agg(jsonb_build_object(
                        'version', v.version, 'action', v.action,
                        'at', to_char(v.submitted_at at time zone 'Asia/Kolkata','DD Mon, FMHH12:MI am'),
                        'components', v.components) order by v.version desc), '[]'::jsonb)
                   from wa_template_versions v where v.template_id = t.id),
      'performance', (select jsonb_build_object(
            'sent', count(*) filter (where r.status in ('sent','delivered','read')),
            'delivered', count(*) filter (where r.status in ('delivered','read')),
            'read', count(*) filter (where r.status = 'read'),
            'failed', count(*) filter (where r.status = 'failed'),
            'clicks', count(*) filter (where r.clicked_at is not null),
            'orders', count(*) filter (where r.order_id is not null),
            'revenue_label', '₹' || to_char(coalesce(sum(r.revenue),0),'FM99,99,99,990.00'),
            'read_pct', case when count(*) filter (where r.status in ('sent','delivered','read')) > 0
                 then round(100.0 * count(*) filter (where r.status='read')
                      / count(*) filter (where r.status in ('sent','delivered','read'))) else 0 end,
            'summary', format('%s sent · %s read · %s clicks · %s orders',
                 count(*) filter (where r.status in ('sent','delivered','read')),
                 count(*) filter (where r.status='read'),
                 count(*) filter (where r.clicked_at is not null),
                 count(*) filter (where r.order_id is not null)))
          from wa_campaign_recipients r join wa_campaigns c2 on c2.id = r.campaign_id
          where c2.template_id = t.id),
      'last_used_label', case when t.last_used_at is not null
          then to_char(t.last_used_at at time zone 'Asia/Kolkata','DD Mon, FMHH12:MI am') else 'Never used' end,
      'can_edit', t.status <> 'PENDING',
      'can_submit', t.status in ('DRAFT','REJECTED') or t.meta_id is null,
      'can_delete', true,
      'can_test_send', t.status = 'APPROVED',
      'can_clone', true,
      'can_use_in_campaign', t.status = 'APPROVED',
      'submitted_label', case when t.submitted_at is not null
          then to_char(t.submitted_at at time zone 'Asia/Kolkata','DD Mon, FMHH12:MI am') end,
      'synced_label', case when t.last_synced_at is not null
          then to_char(t.last_synced_at at time zone 'Asia/Kolkata','DD Mon, FMHH12:MI am') end,
      'last_error', t.last_error) as x
    from wa_templates t where t.hidden_at is null) q;

  v_ts   := coalesce((select value from app_settings where key='wa_test_send'), '{}'::jsonb);
  v_copy := coalesce((select value from app_settings where key='wa_templates_copy'), '{}'::jsonb);

  return jsonb_build_object(
    'ok', true,
    'templates', v_rows,
    'copy', v_copy,
    'counts', jsonb_build_object(
      'total', (select count(*) from wa_templates),
      'approved', (select count(*) from wa_templates where status='APPROVED'),
      'pending', (select count(*) from wa_templates where status='PENDING'),
      'rejected', (select count(*) from wa_templates where status='REJECTED'),
      'paused', (select count(*) from wa_templates where status in ('PAUSED','DISABLED'))),
    'count_chips', jsonb_build_array(
      jsonb_build_object('key','total','label',coalesce(v_copy->>'count_total','Total'),
        'value',(select count(*) from wa_templates),'tone','grey'),
      jsonb_build_object('key','approved','label',coalesce(v_copy->>'count_approved','Approved'),
        'value',(select count(*) from wa_templates where status='APPROVED'),'tone','green'),
      jsonb_build_object('key','pending','label',coalesce(v_copy->>'count_pending','Pending'),
        'value',(select count(*) from wa_templates where status='PENDING'),'tone','yellow'),
      jsonb_build_object('key','rejected','label',coalesce(v_copy->>'count_rejected','Rejected'),
        'value',(select count(*) from wa_templates where status='REJECTED'),'tone','red'),
      jsonb_build_object('key','paused','label',coalesce(v_copy->>'count_paused','Paused'),
        'value',(select count(*) from wa_templates where status in ('PAUSED','DISABLED')),'tone','yellow')),
    'starters', public.wa_template_starters(),
    'tokens', public.wa_template_tokens(),
    'button_spec', public.wa_template_button_spec(),
    'test_send', jsonb_build_object(
      'default_to',   coalesce(v_ts->>'default_to',''),
      'title',        coalesce(v_ts->>'title',''),
      'note',         coalesce(v_ts->>'note',''),
      'field_label',  coalesce(v_ts->>'field_label',''),
      'send_label',   coalesce(v_ts->>'send_label',''),
      'values_title', coalesce(v_ts->>'values_title',''),
      'sent_prefix',  coalesce(v_ts->>'sent_prefix','')),
    'categories', jsonb_build_array(
      jsonb_build_object('key','UTILITY','label','Utility','note','Order updates, alerts — cheapest, not throttled'),
      jsonb_build_object('key','MARKETING','label','Marketing','note','Offers — needs opt-in, ~7x the cost, can be paused'),
      jsonb_build_object('key','AUTHENTICATION','label','Authentication','note','OTP — Meta''s fixed wording')),
    'languages', jsonb_build_array(
      jsonb_build_object('key','en','label','English'),
      jsonb_build_object('key','en_US','label','English (US)'),
      jsonb_build_object('key','hi','label','Hindi')),
    'alerts', (select coalesce(jsonb_agg(jsonb_build_object(
          'template', t.name, 'kind', e.kind, 'detail', e.detail,
          'at', to_char(e.created_at at time zone 'Asia/Kolkata','DD Mon, FMHH12:MI am'),
          -- tone and label live here so the app holds no kind -> colour map
          'tone', case e.kind
              when 'status_paused'   then 'red'
              when 'status_disabled' then 'red'
              when 'status_rejected' then 'red'
              when 'category_changed' then 'yellow'
              when 'quality_drop'     then 'yellow'
              else 'grey' end,
          'label', case e.kind
              when 'status_paused'    then 'Paused by Meta'
              when 'status_disabled'  then 'Disabled by Meta'
              when 'status_rejected'  then 'Rejected by Meta'
              when 'status_approved'  then 'Approved by Meta'
              when 'category_changed' then 'Category changed by Meta'
              when 'quality_drop'     then 'Quality rating dropped'
              else initcap(replace(coalesce(e.kind,''),'_',' ')) end,
          'detail_label', coalesce(e.detail->>'message', e.detail->>'reason',
                                   e.detail->>'note', ''))
          order by e.created_at desc), '[]'::jsonb)
        from (select * from wa_template_events order by created_at desc limit 10) e
        join wa_templates t on t.id = e.template_id),
    'empty', jsonb_build_object('title','No templates yet',
      'note','Start from a ready template below, or write your own — Meta''s verdict appears here automatically'));
end
$function$;

grant execute on function public.wa_templates_screen(text) to authenticated, service_role;
