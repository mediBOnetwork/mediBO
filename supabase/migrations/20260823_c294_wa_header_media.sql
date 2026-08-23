-- CHANGE #294 (part E) — a template whose HEADER is media must be SENT with that
-- media, per message.
--
-- Found while auditing the other customer-facing sends: `bill_to_customer` is an
-- APPROVED template with a DOCUMENT header, but wa-campaign-send only ever sent a
-- BODY component — so that route could never have delivered either. The new
-- `payment_qr` template (IMAGE header carrying the QR) has the same requirement.
--
-- Note the header_format COLUMN is not the authority: `order_placed` carries
-- header_format='IMAGE' from an old draft while its approved components are
-- BODY+FOOTER only. The components are the truth.

alter table public.wa_campaign_recipients
  add column if not exists header_media jsonb;

comment on column public.wa_campaign_recipients.header_media is
  'CHANGE #294 — {type, link} for this ONE message''s media header. Null when the '
  'template has no media header.';

create or replace function public.wa_template_needs_header_media(p_template_id uuid)
returns text
language sql stable security definer set search_path to 'public'
as $$
  select lower(c->>'format')
    from wa_templates t, jsonb_array_elements(coalesce(t.components,'[]'::jsonb)) c
   where t.id = p_template_id
     and upper(coalesce(c->>'type','')) = 'HEADER'
     and upper(coalesce(c->>'format','')) in ('IMAGE','DOCUMENT','VIDEO')
   limit 1;
$$;
