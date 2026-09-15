-- CHANGE #1362 — remove the catalogue export ("Make the PDF") end to end.
--
-- WHY: the action sat above the Catalogue tab's product list and turned the
-- filtered list a visitor was looking at into a downloadable PDF. That is a
-- competitor's scraping job done for them, one tap at a time, so the whole
-- path goes: the two customer-facing RPCs, the two service-role render hooks,
-- the job table, the `export` block in catalogue_extras(), the fifteen
-- catalogue.export_* copy keys and the PDFs already sitting in storage.
--
-- WHAT STAYS: everything else px-invoice draws (POS invoices, settlement
-- invoices, audit and account documents) and the other two Catalogue extras
-- from #748 — "Recently added" and "Missing product?". catalogue_extras_config
-- keeps its export_max column: it holds a number, not a capability, and
-- dropping a column with data is not something a removal command should do on
-- its own. Nothing reads it any more.
--
-- The drops are idempotent so a resumed worker can re-run this file.

drop function if exists public.catalogue_export_start(bigint[], text);
drop function if exists public.catalogue_export_status(uuid);
drop function if exists public.catalogue_export_render_input(uuid);
drop function if exists public.catalogue_export_report(uuid, boolean, text, text, text, integer, text);

drop table if exists public.catalogue_export;

delete from public.ui_copy where key like 'catalogue.export_%';

-- The PDFs that were already built live in the private customer-bills bucket
-- under catalogue/<export id>.pdf. They are purged through the Storage API,
-- not from here: storage.protect_delete() refuses a direct DELETE on
-- storage.objects so that the file and its row can never drift apart. See
-- scripts/c1362_purge_catalogue_pdfs.sh, run once as part of this change.

-- catalogue_extras() without the export block. Everything else is verbatim
-- from the live definition, so this is a removal and not a rewrite.
create or replace function public.catalogue_extras(p_zone boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare c public.catalogue_extras_config%rowtype; v_recent int; v jsonb;
begin
  select * into c from public.catalogue_extras_config where id = 1;
  select count(*) into v_recent from public."MEDICINE"
   where created_at is not null
     and created_at >= now() - make_interval(days => coalesce(c.new_days,30));

  return jsonb_build_object(
    'recent', jsonb_build_object(
      'key',   'recent',
      'kind',  'recent',
      'label', public.uic('catalogue.recent_title','Recently added'),
      'count', v_recent,
      'count_label', public.cat_count_label(v_recent::bigint),
      'show',  v_recent > 0),
    'added', jsonb_build_object(
      'label',      public.uic('catalogue.added_toast','Added to cart'),
      'undo_label', public.uic('catalogue.added_undo','Undo')),
    'peek', jsonb_build_object(
      'title',      public.uic('catalogue.peek_title','Quick look'),
      'open_label', public.uic('catalogue.peek_open','Open full page')),
    'request', jsonb_build_object(
      'show',         coalesce(c.request_open,true),
      'title',        public.uic('catalogue.request_title','Missing product?'),
      'subtitle',     public.uic('catalogue.request_sub','Tell us what you could not find and we will add it.'),
      'submit_label', public.uic('catalogue.request_submit','Send request'),
      'fields', jsonb_build_array(
        jsonb_build_object('key','name',    'label', public.uic('catalogue.request_name','Product name'),    'required', true),
        jsonb_build_object('key','company', 'label', public.uic('catalogue.request_company','Company'),      'required', false),
        jsonb_build_object('key','salt',    'label', public.uic('catalogue.request_salt','Salt / composition'),'required', false),
        jsonb_build_object('key','pack',    'label', public.uic('catalogue.request_pack','Pack'),            'required', false)),
      'photo_label',  public.uic('catalogue.request_photo','Add a photo (optional)')));
end $function$;
