-- CHANGE #353 follow-up — hostile QA on my OWN work found the #25 bug again in
-- the functions #29 introduced. A new SECURITY DEFINER function inherits the
-- default PUBLIC execute grant, so po_retotal (a WRITE that rewrites a PO's
-- totals), po_pricing_block (a supplier's money) and supplier_rate_for (a
-- supplier's trade rates) were all reachable with the anon key that ships in
-- the web bundle. Revoke from PUBLIC, not just anon (#305): anon inherits the
-- PUBLIC grant, and revoking a direct grant it never had is a no-op.
revoke execute on function public.po_retotal(uuid)                     from public, anon, authenticated;
revoke execute on function public.po_pricing_block(uuid)               from public, anon;
revoke execute on function public.supplier_rate_for(text, bigint, date) from public, anon;

grant execute on function public.po_retotal(uuid)                      to service_role;
grant execute on function public.po_pricing_block(uuid)                to authenticated, service_role;
grant execute on function public.supplier_rate_for(text, bigint, date) to authenticated, service_role;

-- inquiry_rate_capture() stays anon-callable ON PURPOSE: the public inquiry
-- form is opened from a WhatsApp link with no session, and the payload is pure
-- UI copy — no supplier, no money, no ids.
grant execute on function public.inquiry_rate_capture() to anon, authenticated, service_role;
