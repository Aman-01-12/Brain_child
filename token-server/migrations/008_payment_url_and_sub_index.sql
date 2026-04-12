-- Migration 008: Add update_payment_method URL + subscription_id index
-- Required for robust LS webhook handling (invoice events look up by subscription_id)

-- Store the pre-signed URL for updating payment method (sent on every subscription webhook)
ALTER TABLE users ADD COLUMN IF NOT EXISTS ls_update_payment_url TEXT;

-- Index for invoice event lookups — payment events carry subscription_id, not user_id
CREATE INDEX IF NOT EXISTS idx_users_ls_subscription
  ON users (ls_subscription_id) WHERE ls_subscription_id IS NOT NULL;
