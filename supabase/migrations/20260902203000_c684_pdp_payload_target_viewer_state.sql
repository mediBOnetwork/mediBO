-- CHANGE #684 — the PDP payload guard stops flapping on the admin's view-as toggle.
--
-- rg_payload_targets.product_detail_181726 collects product_detail(181726) as one
-- pinned viewer: the super admin. Two of the fields it captured are not product
-- truth at all — `show_wishlist` and `availability.gated` are both
-- viewer_is_approved_customer(), which is TRUE while that admin has an
-- admin_acting_as row and FALSE the moment they leave view-as. So every time Om
-- entered or left "view as customer" in the live app the guard reported payload
-- drift, and a runner was spent proving it was nothing (rg_runs 449/450 on
-- 2 Sep 2026: diffs 2, critical 0, and the only delta was gated true -> false and
-- show_wishlist true -> false, with price, stock, supplier, Rx and trust byte
-- identical).
--
-- The target already strips volatile viewer/order-dependent fields on exactly
-- this reasoning (similar / similar_ready / my_history). These two join them.
-- Everything the guard exists to protect — price, stock status, supplier label,
-- Rx gating, trust chips, the CTA block — stays under guard, and the entitlement
-- logic itself keeps its own dedicated behaviour tests
-- (storefront_ptr_entitlement, approved_zone_gate,
-- c678_anon_sees_everything_available).
--
-- Idempotent: a plain UPDATE, a no-op when the row is absent or already correct.
update public.rg_payload_targets
   set sql  = 'select (public.product_detail(181726) - ''similar'' - ''similar_ready'' - ''my_history'' - ''show_wishlist'') #- ''{availability,gated}''',
       note = 'PDP payload, pinned product. Stripped: similar/similar_ready/my_history (volatile until index + order-dependent) and show_wishlist/availability.gated (both are viewer_is_approved_customer(), which flips the moment the pinned admin enters or leaves view-as — live session state, not product truth). Price, stock, supplier, Rx and trust stay under guard.'
 where name = 'product_detail_181726';
