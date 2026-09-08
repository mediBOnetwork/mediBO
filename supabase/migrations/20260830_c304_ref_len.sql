-- CHANGE #304 (g) — Razorpay caps reference_id at 40 characters.
-- "CPO300826CHAO1:advance:<32 hex>" is 55 and the create came back
-- 'reference_id: the length must be no more than 40', which the function
-- correctly reported as an infrastructure failure and fell back to manual UPI.
-- Bounded by construction now: 20 + 1 + 3 + 1 + 12 = 37, whatever the order
-- code's length, and still unique per attempt (12 hex of the attempt uuid).
create or replace function public._rzp_reference_id(p_code text, p_kind text, p_attempt uuid)
returns text language sql immutable set search_path to 'public' as $$
  select left(coalesce(p_code,'ORD'), 20) || ':' || left(coalesce(p_kind,'adv'), 3)
      || ':' || left(replace(p_attempt::text, '-', ''), 12);
$$;
