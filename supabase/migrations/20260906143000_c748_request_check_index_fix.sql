-- CHANGE #748 (repair) — "Missing product?" timed out on every submit.
--
-- catalogue_request_check() is the duplicate guard the request form runs before
-- it submits, and catalogue_request_product() runs it AGAIN on the write, so a
-- failure here takes the whole feature down rather than degrading it. On
-- production it did:
--
--   ERROR: canceling statement due to statement timeout
--   CONTEXT: SQL statement "select ... from public."MEDICINE" m
--             where lower(btrim(m.product_name)) = v_name
--                or lower(btrim(m.product_name)) like v_name || ' %' ..."
--
-- The original comment claimed the lookup was "bounded by the name index". It
-- was not, and this is the scalar-helper-scan trap wearing a different hat:
-- "MEDICINE" carries a plain btree on product_name, but the predicate filters on
-- lower(btrim(product_name)) — a DIFFERENT expression — so no index could be
-- used and every submit seq-scanned 563k rows until statement_timeout killed it.
--
-- The house already normalises product names with _norm_name() (immutable:
-- lower, non-alphanumerics to spaces, whitespace collapsed, trimmed) and already
-- indexes exactly that expression:
--
--   idx_medicine_name_norm_prefix on "MEDICINE" (_norm_name(product_name) text_pattern_ops)
--
-- So the fix adds NO index — a 563k-row table already carrying 36 of them pays
-- ~50 ms per row write for each new one — it just asks the question in the form
-- the existing index can answer. Verified on the production planner: equality
-- and the ' %' prefix each become an Index Scan on idx_medicine_name_norm_prefix
-- (cost 2.6), and the two together a BitmapOr over it (cost 5.2), against a
-- 563k-row sequential scan before.
--
-- It also makes the guard MORE correct, which is why _norm_name is the right
-- normaliser rather than a new index on lower(btrim(...)): "Dolo-650",
-- "DOLO 650" and "Dolo  650" now all count as the product we already stock,
-- which is precisely what a buyer means by "you already have this".
--
-- Idempotent: one create-or-replace, no DDL, no data written.

create or replace function public.catalogue_request_check(
  p_name text, p_company text default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_name text := public._norm_name(coalesce(p_name,'')); v_hit jsonb;
begin
  if v_name = '' then
    return jsonb_build_object('ok', false, 'error','need_name',
      'message', public.uic('catalogue.request_need_name','Please enter the product name.'));
  end if;

  -- _norm_name() strips every character outside [a-z0-9 ], so v_name can carry
  -- no LIKE metacharacter and needs no escaping for the prefix match below.
  select jsonb_build_object('id', m.id, 'name', m.product_name, 'company', m.marketer)
    into v_hit
    from public."MEDICINE" m
   where public._norm_name(m.product_name) = v_name
      or public._norm_name(m.product_name) like v_name || ' %'
   order by (public._norm_name(m.product_name) = v_name) desc, m.id
   limit 1;

  if v_hit is null then
    return jsonb_build_object('ok', true, 'duplicate', false);
  end if;
  return jsonb_build_object('ok', true, 'duplicate', true, 'product', v_hit,
    'message', public.uic('catalogue.request_dupe','We already have this — here it is.'),
    'cta',     public.uic('catalogue.request_dupe_cta','Open it'));
end $$;

grant execute on function public.catalogue_request_check(text,text) to authenticated;
