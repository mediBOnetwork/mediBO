-- replay-target: production
-- CMD #1812 — Part B. Nothing calls the status layer any more (Part A rewrote
-- every caller), so the helpers, the policy table, the copy keys and finally the
-- two scraped columns go. Zone standby is the only availability truth left.

-- The helpers. med_status_block built the red badge, med_status_sellable was the
-- verdict, _med_status_key salvaged a key out of the ~6,200 rows that carried the
-- reason glued onto the status word ("DISCONTINUEDWE DO NOT FACILITATE SALE...").
DROP FUNCTION IF EXISTS public.med_status_block(text);
DROP FUNCTION IF EXISTS public.med_status_sellable(text);
DROP FUNCTION IF EXISTS public._med_status_key(text);
-- catalogue_universe_ok read the same column to hide 'BANNED FOR SALE' from the
-- browse universe. A 1mg word does not get to trim mediBO's catalogue either.
DROP FUNCTION IF EXISTS public.catalogue_universe_ok(text);

DROP TABLE IF EXISTS public.medicine_status_policy;

-- The copy keys that only ever spoke for that layer.
DELETE FROM public.ui_copy
 WHERE key IN ('storefront.status_blocked_note', 'storefront.not_for_sale_label');
DELETE FROM public.storefront_ui_label WHERE key = 'not_for_sale_label';

-- Indexes. Two exist only to search by the column; two more carry it as a
-- partial predicate and are rebuilt on the image test alone.
DROP INDEX IF EXISTS public.idx_medicine_status;
DROP INDEX IF EXISTS public.idx_medicine_status_name;
DROP INDEX IF EXISTS public.idx_medicine_class_img_keyset;
DROP INDEX IF EXISTS public.idx_medicine_name_keyset;
CREATE INDEX idx_medicine_class_img_keyset
    ON public."MEDICINE" USING btree (therapeutic_class, product_name)
 WHERE (image_url_1 IS NOT NULL);
CREATE INDEX idx_medicine_name_keyset
    ON public."MEDICINE" USING btree (product_name)
 WHERE (image_url_1 IS NOT NULL);

-- The columns themselves. scrapping_status is a different field (the scraper's
-- own progress marker) and stays.
ALTER TABLE public."MEDICINE"
  DROP COLUMN IF EXISTS status,
  DROP COLUMN IF EXISTS status_reason;
