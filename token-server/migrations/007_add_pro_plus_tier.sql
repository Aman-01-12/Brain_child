-- Migration 007: Add 'pro+' tier to users_tier_check constraint
-- Required because VARIANT_ID_TO_TIER in billing.js maps variant 1516865 → 'pro+'

ALTER TABLE users DROP CONSTRAINT IF EXISTS users_tier_check;
ALTER TABLE users ADD CONSTRAINT users_tier_check CHECK (tier IN ('free', 'pro', 'pro+', 'hiring'));
