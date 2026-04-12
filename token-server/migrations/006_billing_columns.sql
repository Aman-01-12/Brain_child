-- ============================================================================
-- Migration 006: Lemon Squeezy billing columns (Phase C)
--
-- Adds: billing columns on users, processed_webhook_events, user_tier_history
-- Provider: Lemon Squeezy (Merchant of Record)
-- ============================================================================

-- 1. Billing columns on users table
ALTER TABLE users
  ADD COLUMN IF NOT EXISTS subscription_status    VARCHAR(20) DEFAULT 'none'
    CHECK (subscription_status IN ('none', 'on_trial', 'active', 'past_due', 'unpaid', 'cancelled', 'expired', 'paused')),
  ADD COLUMN IF NOT EXISTS ls_customer_id         VARCHAR(255),
  ADD COLUMN IF NOT EXISTS ls_subscription_id     VARCHAR(255),
  ADD COLUMN IF NOT EXISTS ls_variant_id          VARCHAR(255),
  ADD COLUMN IF NOT EXISTS ls_product_id          VARCHAR(255),
  ADD COLUMN IF NOT EXISTS grace_until            TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS trial_ends_at          TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS current_period_ends_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS ls_portal_url          TEXT,
  ADD COLUMN IF NOT EXISTS deleted_at             TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS deletion_reason        VARCHAR(100);

-- 2. Index for webhook user lookup by LS customer ID (fallback path)
CREATE INDEX IF NOT EXISTS idx_users_ls_customer
  ON users (ls_customer_id) WHERE ls_customer_id IS NOT NULL;

-- 3. Idempotency table — prevents double-processing of replayed webhook events
--    LS delivers webhooks at-least-once (up to 4 attempts on non-200).
CREATE TABLE IF NOT EXISTS processed_webhook_events (
    event_id     VARCHAR(255) PRIMARY KEY,
    event_type   VARCHAR(100) NOT NULL,
    processed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 4. Tier change audit trail — append-only (per SYSTEM_PRINCIPLES §5.5)
--    NEVER UPDATE or DELETE rows from this table.
CREATE TABLE IF NOT EXISTS user_tier_history (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID REFERENCES users(id) ON DELETE SET NULL,
    from_tier   VARCHAR(20),
    to_tier     VARCHAR(20) NOT NULL,
    reason      VARCHAR(100) NOT NULL,
    event_id    VARCHAR(255),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 5. Auto-clean old event IDs after 30 days (run via pg_cron or external cron)
-- DELETE FROM processed_webhook_events WHERE processed_at < NOW() - INTERVAL '30 days';
