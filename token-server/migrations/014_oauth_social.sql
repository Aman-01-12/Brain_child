-- Migration 014: OAuth social sign-in tables (Phase F)
-- Creates oauth_identities for provider→user linking
-- and pending_oauth_handoffs for secure Mac app ↔ server token exchange.

-- OAuth provider identities linked to Inter user accounts
CREATE TABLE IF NOT EXISTS oauth_identities (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id          UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    provider         VARCHAR(32) NOT NULL,           -- 'google' | 'microsoft'
    provider_user_id VARCHAR(255) NOT NULL,           -- Google 'sub' / Microsoft 'oid'
    provider_email   VARCHAR(254),                    -- email from provider at link time
    linked_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_used_at     TIMESTAMPTZ,
    UNIQUE (provider, provider_user_id)               -- one identity per provider slot
);

CREATE INDEX IF NOT EXISTS idx_oauth_identities_user
    ON oauth_identities(user_id);

-- Short-lived codes for the Mac app ↔ server handoff.
-- Tokens never touch URLs — only these opaque codes do.
CREATE TABLE IF NOT EXISTS pending_oauth_handoffs (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code_hash   BYTEA NOT NULL UNIQUE,                -- SHA-256 of the random code
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    expires_at  TIMESTAMPTZ NOT NULL,                 -- NOW() + 30 seconds
    used_at     TIMESTAMPTZ                           -- NULL = not yet redeemed
);

CREATE INDEX IF NOT EXISTS idx_poh_code
    ON pending_oauth_handoffs(code_hash) WHERE used_at IS NULL;
