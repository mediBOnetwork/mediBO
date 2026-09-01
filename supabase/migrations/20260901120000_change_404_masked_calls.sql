-- CHANGE #404 — NUMBER MASKING LAYER (schema)
--
-- Before this migration two people on the same order exchanged REAL phone
-- numbers: my_delivery_run() handed the rider `actions.call_number` straight
-- off orders.phone, and the rider's device dialled it. Once a number has left
-- the platform it is gone — there is no way to revoke it when the order closes,
-- no record that the call happened, and no rule about who may ring whom.
--
-- This is the storage half of the fix. Five party sources become ONE view, a
-- data table decides which role pairs may ever connect, a DID pool holds the
-- masking numbers, a session ties (caller, callee, DID) to an order for a
-- bounded window, and every provider leg is logged.
--
-- Nothing here dials anything. The provider adapter lives in the `mask-call`
-- edge function, and it is provider-agnostic on purpose: Exotel is first, the
-- stub is what every test and every un-provisioned environment runs against.
--
-- SUPPLIER SAFETY (spec, verbatim): supplier phone numbers are dummy
-- 9000000xxx placeholders during the build. Nothing in this change may dial or
-- message a supplier — the allow matrix seeds partner->supplier as the only
-- supplier edge, and even that resolves through a DID.

-- ─────────────────────────────────────────────────────────────────────────
-- 1. E.164 normaliser. Every phone in this layer is stored and compared in
--    one shape, so a webhook's "+919812345678" matches a profile's
--    "98123 45678". India-only by design (the about doc: one market, INR/IST).
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public._call_e164(p_raw text)
returns text
language sql
immutable
set search_path to 'public'
as $$
  with d as (select regexp_replace(coalesce(p_raw,''), '[^0-9]', '', 'g') as n)
  select case
    when length(n) = 10 and left(n,1) between '6' and '9' then '+91' || n
    when length(n) = 11 and left(n,1) = '0'                then '+91' || right(n,10)
    when length(n) = 12 and left(n,2) = '91'               then '+'   || n
    when length(n) = 13 and left(n,3) = '910'              then '+91' || right(n,10)
    when length(n) between 8 and 15                        then '+'   || n
    else ''
  end
  from d;
$$;

comment on function public._call_e164(text) is
  'CHANGE #404 — one phone shape for the masking layer. Empty string means "no usable number", never null-vs-empty ambiguity.';

-- ─────────────────────────────────────────────────────────────────────────
-- 2. call_parties — the five party sources as one addressable list.
--
--    party_id is TEXT because the sources disagree (uuid everywhere except
--    partner_users.id, which is bigint). Casting at the edge once beats a
--    five-way union of mismatched types at every call site.
--
--    This view carries real phone numbers, so it is NOT readable by the app:
--    only service_role and the SECURITY DEFINER functions below may see it.
-- ─────────────────────────────────────────────────────────────────────────
create or replace view public.call_parties as
  -- customer — a licensed pharmacy/clinic buying trade stock
  select 'customer'::text                      as party_role,
         pp.id::text                           as party_id,
         pp.user_id                            as auth_user_id,
         coalesce(nullif(btrim(pp.pharmacy_name),''),
                  nullif(btrim(pp.customer_name),''),
                  nullif(btrim(pp.owner_name),''), '')  as display_name,
         public._call_e164(coalesce(nullif(btrim(pp.phone),''),
                                    nullif(btrim(pp.whatsapp_no),''),
                                    nullif(btrim(pp.other_contact_no),''))) as phone_e164,
         (lower(coalesce(pp.status,'')) in ('approved','active'))           as is_active
  from public.pharmacy_profiles pp
  union all
  -- supplier — wholesale distributor. DUMMY 9000000xxx numbers during build.
  select 'supplier', sp.id::text, sp.user_id,
         coalesce(nullif(btrim(sp.supplier_name),''),
                  nullif(btrim(sp.contact_name),''),
                  nullif(btrim(sp.contact_person),''), ''),
         public._call_e164(coalesce(nullif(btrim(sp.phone),''),
                                    nullif(btrim(sp.contact_no),''),
                                    nullif(btrim(sp.whatsapp_no),''))),
         (lower(coalesce(sp.status,'')) in ('approved','active'))
  from public.supplier_profiles sp
  union all
  -- employee — admin / super-admin / worker / MR, all of whom carry a profile
  select 'employee', up.id::text, up.id,
         coalesce(nullif(btrim(up.full_name),''),
                  nullif(btrim(up.business_name),''), ''),
         public._call_e164(coalesce(nullif(btrim(up.phone),''),
                                    nullif(btrim(up.whatsapp_number),''),
                                    nullif(btrim(up.other_contact),''))),
         true
  from public.user_profiles up
  union all
  -- delivery — the rider or agency moving the order
  select 'delivery', dp.id::text, dp.user_id,
         coalesce(nullif(btrim(dp.full_name),''), ''),
         public._call_e164(dp.phone),
         (coalesce(dp.is_active,false)
          and lower(coalesce(dp.status,'')) in ('approved','active'))
  from public.delivery_partner_registrations dp
  union all
  -- partner staff — identity is a phone for some rows and a login for others,
  -- so fall through to the linked auth user's profile before giving up.
  select 'partner', pu.id::text, pu.auth_user_id,
         coalesce(nullif(btrim(pu.display_name),''), ''),
         coalesce(
           nullif(public._call_e164(pu.identity), ''),
           public._call_e164(up.phone)),
         (coalesce(pu.is_active,false) and coalesce(rp.is_active,true))
  from public.partner_users pu
  left join public.user_profiles up on up.id = pu.auth_user_id
  left join public.region_partners rp on rp.id = pu.partner_id;

comment on view public.call_parties is
  'CHANGE #404 — the five party sources (customer/supplier/employee/delivery/partner) as one (role, id, name, E.164) list. Carries real numbers: service_role only.';

revoke all on public.call_parties from anon, authenticated;
grant select on public.call_parties to service_role;

-- ─────────────────────────────────────────────────────────────────────────
-- 3. The allow matrix — DATA, not an if-tree. Adding "delivery may ring the
--    zone partner" is one INSERT, never a deploy.
-- ─────────────────────────────────────────────────────────────────────────
create table if not exists public.call_allow_matrix (
  caller_role text    not null,
  callee_role text    not null,
  allowed     boolean not null default true,
  note        text,
  updated_at  timestamptz not null default now(),
  primary key (caller_role, callee_role)
);

comment on table public.call_allow_matrix is
  'CHANGE #404 — which role pair may ever be connected. A pair with no row is DENIED (closed by default).';

insert into public.call_allow_matrix (caller_role, callee_role, allowed, note) values
  ('customer','delivery', true,  'The rider at the door and the pharmacy expecting the bag.'),
  ('delivery','customer', true,  'Same edge, other direction.'),
  ('customer','partner',  true,  'The buyer and the zone partner fulfilling the order.'),
  ('partner','customer',  true,  'Same edge, other direction.'),
  ('partner','supplier',  true,  'Fulfilment chasing stock. The ONLY supplier edge.'),
  ('supplier','partner',  true,  'Same edge, other direction.'),
  ('employee','customer', true,  'Ops can reach anyone on an order.'),
  ('employee','supplier', true,  'Ops can reach anyone on an order.'),
  ('employee','delivery', true,  'Ops can reach anyone on an order.'),
  ('employee','partner',  true,  'Ops can reach anyone on an order.'),
  ('employee','employee', true,  'Ops to ops.'),
  ('customer','employee', true,  'Ops is reachable from every role.'),
  ('supplier','employee', true,  'Ops is reachable from every role.'),
  ('delivery','employee', true,  'Ops is reachable from every role.'),
  ('partner','employee',  true,  'Ops is reachable from every role.'),
  -- Explicit denials. A row saying no is louder than an absent row, and it
  -- gives the refusal somewhere to carry its reason.
  ('customer','supplier', false, 'A buyer never reaches a distributor directly — that is the whole waterfall.'),
  ('supplier','customer', false, 'Same edge, other direction.'),
  ('delivery','supplier', false, 'A rider has no business with a distributor.'),
  ('supplier','delivery', false, 'Same edge, other direction.'),
  ('delivery','partner',  false, 'Riders route through ops, not through fulfilment.'),
  ('partner','delivery',  false, 'Same edge, other direction.')
on conflict (caller_role, callee_role) do nothing;

-- ─────────────────────────────────────────────────────────────────────────
-- 4. The DID pool — the masking numbers themselves.
-- ─────────────────────────────────────────────────────────────────────────
create table if not exists public.call_did_pool (
  id          bigserial primary key,
  did         text    not null unique,
  provider    text    not null default 'exotel',
  is_active   boolean not null default true,
  note        text,
  last_used_at timestamptz,
  created_at  timestamptz not null default now()
);

comment on table public.call_did_pool is
  'CHANGE #404 — the masking numbers (ExoPhones). Empty until Om buys them; the stub provider mints its own so nothing blocks on procurement.';

-- The stub DID exists so the whole chain is testable with zero telephony spend.
-- It is provider=stub, so a live Exotel session can never be handed it.
insert into public.call_did_pool (did, provider, is_active, note)
values ('+919000000000', 'stub', true, 'CHANGE #404 — stub-provider DID. Never dialled; tests and un-provisioned environments use it.')
on conflict (did) do nothing;

-- ─────────────────────────────────────────────────────────────────────────
-- 5. Sessions — (caller, callee, DID) bound to an order for a bounded window.
-- ─────────────────────────────────────────────────────────────────────────
create table if not exists public.call_sessions (
  id              uuid primary key default gen_random_uuid(),
  order_id        uuid references public.orders(id) on delete cascade,
  caller_role     text not null,
  caller_party_id text not null,
  caller_phone    text not null,
  callee_role     text not null,
  callee_party_id text not null,
  callee_phone    text not null,
  did             text not null,
  provider        text not null default 'stub',
  provider_sid    text,
  status          text not null default 'active',
  expires_at      timestamptz not null,
  created_at      timestamptz not null default now(),
  created_by      uuid,
  closed_at       timestamptz,
  close_reason    text
);

comment on table public.call_sessions is
  'CHANGE #404 — one masked connection. status: active | expired | closed | failed. Expires on its own clock AND on order delivery/closure.';

create index if not exists call_sessions_did_active_idx
  on public.call_sessions (did, status, expires_at desc);
create index if not exists call_sessions_caller_idx
  on public.call_sessions (caller_phone, status, expires_at desc);
create index if not exists call_sessions_order_idx
  on public.call_sessions (order_id, status);
create index if not exists call_sessions_open_idx
  on public.call_sessions (status, expires_at) where status = 'active';

-- ─────────────────────────────────────────────────────────────────────────
-- 6. masked_calls — every provider leg, whatever the provider.
-- ─────────────────────────────────────────────────────────────────────────
create table if not exists public.masked_calls (
  id            bigserial primary key,
  session_id    uuid references public.call_sessions(id) on delete set null,
  order_id      uuid,
  provider      text not null,
  provider_sid  text,
  leg           text,
  direction     text,
  did           text,
  status        text,
  duration_s    integer,
  recording_url text,
  raw           jsonb,
  created_at    timestamptz not null default now()
);

comment on table public.masked_calls is
  'CHANGE #404 — the call log. One row per provider leg (outbound connect, inbound match, status callback), with duration and recording url when the provider supplies them.';

create index if not exists masked_calls_session_idx on public.masked_calls (session_id, created_at desc);
create index if not exists masked_calls_sid_idx     on public.masked_calls (provider_sid);
create index if not exists masked_calls_order_idx   on public.masked_calls (order_id, created_at desc);

-- ─────────────────────────────────────────────────────────────────────────
-- 7. call_config — the non-secret half of the provider setup.
--    EXOTEL_SID / EXOTEL_TOKEN are edge-function secrets and NEVER live here.
-- ─────────────────────────────────────────────────────────────────────────
create table if not exists public.call_config (
  id               boolean primary key default true check (id),
  enabled          boolean not null default true,
  provider         text    not null default 'stub',
  session_ttl_min  integer not null default 240,
  exotel_subdomain text    not null default 'api.exotel.com',
  exotel_caller_id text    not null default '',
  record_calls     boolean not null default false,
  updated_at       timestamptz not null default now()
);

comment on table public.call_config is
  'CHANGE #404 — provider selection and session TTL. Secrets (EXOTEL_SID/EXOTEL_TOKEN) are edge-function env, never a DB column.';

insert into public.call_config (id) values (true) on conflict (id) do nothing;

-- ─────────────────────────────────────────────────────────────────────────
-- 8. RLS. Every table here is service-role territory: the app reaches this
--    layer only through the SECURITY DEFINER functions in the next migration
--    and through the mask-call edge function. Enabling RLS with no policy is
--    the closed default — service_role bypasses it, everyone else sees zero
--    rows even if a grant is added by accident later.
-- ─────────────────────────────────────────────────────────────────────────
alter table public.call_allow_matrix enable row level security;
alter table public.call_did_pool     enable row level security;
alter table public.call_sessions     enable row level security;
alter table public.masked_calls      enable row level security;
alter table public.call_config       enable row level security;

revoke all on public.call_sessions, public.masked_calls, public.call_did_pool,
              public.call_config, public.call_allow_matrix
  from anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 9. Copy. Every word the masked-call surfaces print lives here — a label
--    change is an UPDATE, not a deploy.
-- ─────────────────────────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('call.button_customer',   '"Call pharmacy"'::jsonb),
  ('call.button_delivery',   '"Call rider"'::jsonb),
  ('call.button_partner',    '"Call partner"'::jsonb),
  ('call.button_supplier',   '"Call supplier"'::jsonb),
  ('call.button_employee',   '"Call mediBO"'::jsonb),
  ('call.connecting',        '"Connecting your call…"'::jsonb),
  ('call.placed',            '"Connecting — your phone will ring first."'::jsonb),
  ('call.dial_hint',         '"Dial the number shown. Both sides stay private."'::jsonb),
  ('call.privacy_note',      '"Numbers are masked. Neither side sees the other."'::jsonb),
  ('call.not_allowed',       '"This call is not permitted."'::jsonb),
  ('call.no_target',         '"Nobody is assigned to call on this order yet."'::jsonb),
  ('call.no_number',         '"No reachable number on file."'::jsonb),
  ('call.expired',           '"This call link has expired."'::jsonb),
  ('call.session_closed',    '"The order is closed, so calling is switched off."'::jsonb),
  ('call.disabled',          '"Masked calling is switched off."'::jsonb),
  ('call.no_did',            '"No masking number is available right now."'::jsonb),
  ('call.provider_failed',   '"The calling service did not answer. Try again."'::jsonb),
  ('call.stub_notice',       '"Test mode — no real call is placed."'::jsonb),
  ('call.setup_title',       '"Masked calling"'::jsonb)
on conflict (key) do nothing;
