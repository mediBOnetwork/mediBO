-- CHANGE #750 — the regression guard stops crying wolf about a product photo.
--
-- WHAT WENT RED. rg run 572 (03 Sep 01:21 UTC) failed with exactly one diff:
-- payload target `my_orders_chandra_slice` changed, reconfirmed. Zero function,
-- column, policy, trigger, index, cron or setting diffs, and every behaviour
-- green — so nothing about the CODE that builds that payload had moved. Only
-- its inputs had.
--
-- WHICH INPUT. The target hashes a whole live order slice, and
-- `my_orders_screen()` builds each line's `image_url` from
-- `MEDICINE.image_url_1`. Ten of that order's twelve products carry an image
-- today and two still do not — the image backfill is working through the
-- catalogue, and every time it fills one of those two (or replaces any of the
-- other ten) this target changes and the guard goes red on a photo. It is
-- guaranteed to fire at least twice more.
--
-- THE FIX IS THE TABLE'S OWN CONVENTION. Every other volatile target here is
-- already narrowed: `product_detail_181726` strips `similar` / `my_history` /
-- `show_wishlist` and says why in its note; `company_page_sun_skeleton` and
-- `storefront_home_v2_skeleton` keep the structure and drop the churn. This one
-- was the odd row out. `image_url` is dropped from every line and NOTHING else
-- is: price, rate, line and order totals, status text and tone, the edit gate,
-- the batch block, the unfulfilled block and the full key structure all stay
-- under guard. A field is only ever stripped with the evidence that it moves on
-- its own — an unevidenced strip is a weaker guard pretending to be a fix.
--
-- Idempotent (#233).

begin;

update public.rg_payload_targets
   set sql = $q$select (
         select jsonb_set(o, '{lines}', coalesce((
                  select jsonb_agg(l - 'image_url' order by l->>'product_id')
                    from jsonb_array_elements(o->'lines') l), '[]'::jsonb))
           from jsonb_array_elements(public.my_orders_screen(null)->'orders') o
          where o->>'id' = '6c376217-4e92-419f-99f5-ab4d202375f5'
          limit 1)$q$,
       note = 'customer Items tab feed, pinned order CPO310726CHAO1 '
              '| re-pinned Aug 2: order user_id re-linked during #636 identity fix '
              '| #750: line.image_url stripped — MEDICINE.image_url_1 is filled by '
              'the image backfill (10 of this order''s 12 products had a photo, 2 '
              'did not), so the whole-slice hash went red on a picture arriving. '
              'Everything else — price, totals, status, edit gate, batch block, '
              'unfulfilled block, key structure — stays under guard.'
 where name = 'my_orders_chandra_slice';

commit;
