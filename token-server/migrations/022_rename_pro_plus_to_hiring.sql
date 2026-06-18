-- ---------------------------------------------------------------------------
-- 022_rename_pro_plus_to_hiring.sql
--
-- Collapse the tier model back to exactly free < pro < hiring. The previous
-- "pro+" tier WAS the hiring/interview plan, just mislabeled; migration 007 had
-- widened the constraint to allow 'pro+'. This migration:
--   1. Drops the widened constraint so existing 'pro+' rows can be rewritten.
--   2. Carries over any existing subscribers: tier 'pro+' → 'hiring'
--      (a no-op when there are none).
--   3. Re-tightens the constraint to ('free','pro','hiring').
--
-- The billing variant that mapped to 'pro+' (1516865) now maps to 'hiring' via
-- billing-page.js, so future checkouts write 'hiring' directly. user_tier_history
-- has no tier check constraint, so historical 'pro+' rows there are left intact.
-- ---------------------------------------------------------------------------

-- 1. Drop the constraint added by 007 (name is stable across 001/007).
ALTER TABLE users DROP CONSTRAINT IF EXISTS users_tier_check;

-- 2. Carry existing Pro+/hiring subscribers over to the canonical tier name.
UPDATE users SET tier = 'hiring' WHERE tier = 'pro+';

-- 3. Re-tighten: only free / pro / hiring are valid tiers going forward.
ALTER TABLE users ADD CONSTRAINT users_tier_check CHECK (tier IN ('free', 'pro', 'hiring'));
