-- CHANGE cmd #644 — the Google Play store listing text lives in ui_copy.
--
-- The listing is COPY. It changes far more often than the app does, and every
-- previous edit meant retyping prose into the Play console with no record of
-- what was sent. These three rows are now the source of truth: an editor
-- changes ui_copy, and `python3 scripts/play_ops.py listing --short-file …
-- --full-file …` pushes exactly that text through edits.listings.patch.
--
-- Idempotent by construction: on conflict the value is overwritten, so a
-- resumed worker re-applying this migration is a silent no-op.
--
-- Play's own limits, asserted below so a future edit cannot quietly ship a
-- string Play would reject: shortDescription <= 80, fullDescription <= 4000.

insert into ui_copy (key, value) values
  ('play_listing.short',    to_jsonb($medibo644$Order stock, bill customers, run your whole pharmacy — one free app.$medibo644$::text)),
  ('play_listing.full',     to_jsonb($medibo644$Your whole pharmacy in one app.

mediBO is the operating system for India's pharmacies. Order stock from 5.6 lakh+ medicines across 18,000+ companies, bill customers at the counter, and run inventory, khata, expiry and GST from one place — free. Built for licensed pharmacies, chemists, hospitals and clinics.

ORDER STOCK
• 5.6 lakh+ medicines, 18,000+ companies, every therapeutic class
• Order by search, barcode scan, or a photo of your handwritten list on WhatsApp
• Upload your order list and let AI match it to the right products
• Every order is fulfilled, invoiced and supplied by the licensed wholesale distributor serving your zone
• Receive stock fast with voice and barcode counting
• Live tracking, same-day delivery, digital bills, payment tracking and easy dispute resolution

BILL YOUR CUSTOMERS (POS)
• Fast counter billing with GST invoice PDF
• Per-bill UPI QR paid straight to your own bank account — money never touches mediBO
• Prescription photo to draft bill in seconds
• Patient khata (credit ledger) with WhatsApp payment reminders
• Refill reminders that bring patients back every month

MANAGE YOUR SHOP
• Inventory that builds itself from your mediBO purchases — no manual entry
• Expiry radar on WhatsApp: know what will expire before it costs you money
• Auto-reorder from your real sales speed; margin finder on same-salt alternatives
• Owner dashboard with sales, margins, dead stock and benchmarks
• GST pack: purchase and sales registers, GSTR-1/3B exports, one-click CA pack
• Dead-stock exchange and emergency borrow between mediBO pharmacies

Built for registered businesses holding a valid drug licence. mediBO is not intended for consumers.$medibo644$::text)),
  ('play_listing.language', to_jsonb('en-US'::text))
on conflict (key) do update
  set value = excluded.value,
      updated_at = now();

do $guard$
declare
  s text := (select value #>> '{}' from ui_copy where key = 'play_listing.short');
  f text := (select value #>> '{}' from ui_copy where key = 'play_listing.full');
begin
  if s is null or f is null then
    raise exception 'cmd #644: play_listing copy did not land in ui_copy';
  end if;
  if length(s) > 80 then
    raise exception 'cmd #644: play_listing.short is % chars; Play allows 80', length(s);
  end if;
  if length(f) > 4000 then
    raise exception 'cmd #644: play_listing.full is % chars; Play allows 4000', length(f);
  end if;
end
$guard$;
