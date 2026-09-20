-- CMD #2130 — RG red after #1458: privileged_rpcs_are_not_anon.
--
-- CMD #2118 (company discovery) granted storefront_company_search to anon on
-- purpose: it feeds the Companies block on the public storefront search
-- (lib/widgets/company_hits_block.dart via storefront_search_page), exactly
-- like storefront_search_page / storefront_company_page, which are already on
-- the allow list. It returns only public company names and buyable counts.
-- The grant is intentional, so it is recorded here rather than revoked.
-- Idempotent.
insert into public.rpc_anon_allow (fn_name, reason)
values ('storefront_company_search',
        'CMD #2118 — the Companies block on the public storefront search (company names + buyable counts only), like storefront_search_page/storefront_company_page. Recorded by CMD #2130.')
on conflict (fn_name) do nothing;
