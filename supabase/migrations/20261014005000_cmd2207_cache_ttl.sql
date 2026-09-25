-- CMD #2207 wave 5 — the card cache was never being served.
--
-- MEASURED ON LIVE (25 Sep 2026, after CHANGE #1543): public.sf_card_cache held
-- 12,073 rows and only 848 of them were inside the 900 s TTL that
-- public._search_cards() and public._sf_cards() require before they will serve a
-- cached card. 93 % of the cache was unservable, so every search / company /
-- product list rebuilt all 20 cards live (public._product_card 2.9 ms per card,
-- ~58 ms per page) and paid for a cache it could not use.
--
-- The cause is a mismatch between two numbers, not a bug in the lookup:
-- public.sf_card_warm_tick() refreshes ONE class per run inside its 15 s budget
-- and the classes rotate, so a given card is rewritten roughly every 25-45 min
-- (observed built_at spread: 02:35 -> 03:20 IST over three classes). A 15-minute
-- TTL can therefore never cover a 45-minute refresh cycle.
--
-- The TTL is raised to 5400 s (90 min) — twice the observed worst cycle, so a
-- warmed card stays servable until the tick rewrites it. Staleness is bounded by
-- the CYCLE (~45 min), not by the TTL, because every cycle rewrites the row; and
-- it is display staleness only: the cache is skipped outright for any product in
-- the viewer's cart, notify list or wishlist, and order pricing is recomputed
-- server-side at checkout, never read from a card.
--
-- Eviction follows automatically: the tick deletes at ttl * 3, i.e. 4.5 h.
--
-- Guarded so it can only ever move the ORIGINAL default: if Om (or a later
-- command) has already tuned this knob, this migration leaves it alone. That
-- keeps the file idempotent for the replay ledger without clobbering an
-- operator's value.

update public.app_settings
   set value = to_jsonb(5400)
 where key = 'sf_card_cache_ttl_s'
   and (value #>> '{}')::int = 900;

insert into public.app_settings (key, value)
select 'sf_card_cache_ttl_s', to_jsonb(5400)
 where not exists (select 1 from public.app_settings where key = 'sf_card_cache_ttl_s');

-- ── the warmer was the spike it was supposed to prevent ────────────────────
--
-- pg_stat_statements on live, same window: public.sf_card_warm_tick() ran with a
-- mean of 18.2 s and a worst case of 384 s, and every customer RPC in the same
-- window carried a max of 4-7 s — storefront_labels(), a 1.1 ms function, spiked
-- to 732 ms. The instance has 60 connections; a warmer that holds one for six
-- minutes every five minutes is not a cache, it is the contention.
--
-- The tick already checks its budget between batches. It could not help: one
-- batch was sf_card_warm_batch = 1500 products, and public._sf_cards(1500) is a
-- SINGLE statement building 1500 x 4.9 kB of JSON, so the clock was only read
-- once the damage was done. Bounding the STATEMENT is what bounds the tick.
--
-- batch 1500 -> 250 (about 0.7 s of card building per statement, measured at
-- 2.9 ms per card) and budget 15 s -> 10 s. Measured immediately after: one tick
-- = 15.2 s wall, one class built, two deferred to the next tick — the rotation
-- the design always assumed, now actually honoured.
--
-- Same guard as above: only the original default is moved.

update public.app_settings
   set value = to_jsonb(250)
 where key = 'sf_card_warm_batch'
   and (value #>> '{}')::int = 1500;

update public.app_settings
   set value = to_jsonb(10000)
 where key = 'sf_card_warm_budget_ms'
   and (value #>> '{}')::int = 15000;
