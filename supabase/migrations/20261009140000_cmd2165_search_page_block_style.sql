-- CMD #2165 — the Companies block's redline, on the RPC the app actually calls.
--
-- `search_page()` (CMD #1906) is the ONE search RPC for Home and the Catalogue,
-- and it already carries companies[] / companies_has / companies_title /
-- companies_rpc. Two things were still decided in the client:
--
--   • the heading's CASE — the design prints it in caps, so the backend sends
--     it in caps and Dart prints the string it was given;
--   • every SIZE and COLOUR of the block (60dp row, 40dp tile, 14.5 / 12.5 /
--     13 sp text, #E8F5EE on #1B7A43). Those sit between the Ds type steps, so
--     rather than becoming literals in a screen they travel as companies_style
--     and are retuned with one app_settings UPDATE and no deploy.
--
-- Idempotent: CREATE OR REPLACE over the same signature; the settings row is
-- seeded by 20261009120000 and only read here.

create or replace function public.search_page(
  p_q text,
  p_filters jsonb default '{}'::jsonb,
  p_page integer default 0,
  p_page_size integer default null,
  p_zone boolean default true)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  r jsonb;
  v_c jsonb := '[]'::jsonb;
  v_style jsonb;
begin
  r := public._search_page_core(p_q, p_filters, p_page, p_page_size, p_zone);
  -- Om 22 Sep: up to 3 fuzzy company matches, first page only, above the products.
  if coalesce(p_page,0) = 0 and length(btrim(coalesce(p_q,''))) >= 3 then
    begin v_c := public.search_company_matches(p_q, 3); exception when others then v_c := '[]'::jsonb; end;
  end if;

  v_style := coalesce((select value from public.app_settings
                        where key = 'search_companies_style'), '{}'::jsonb);

  return r || jsonb_build_object(
    'companies', v_c,
    'companies_has', jsonb_array_length(v_c) > 0,
    -- CMD #2165 — sent in the case it is printed in.
    'companies_title', upper(public.uic('search.companies_title','Companies')),
    'companies_rpc', 'storefront_company_page',
    'companies_style', v_style);
end $function$;

grant execute on function public.search_page(text, jsonb, integer, integer, boolean)
  to anon, authenticated;
