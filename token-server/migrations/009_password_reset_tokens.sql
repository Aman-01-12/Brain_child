-- Phase D.1a: Password reset tokens
-- Single-use, SHA-256 hashed, 1-hour expiry.
-- Raw token sent by email; only the hash is stored.

CREATE TABLE password_reset_tokens (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash  BYTEA NOT NULL UNIQUE,
    expires_at  TIMESTAMPTZ NOT NULL,
    used_at     TIMESTAMPTZ  -- NULL = unused. Set on first use.
);

CREATE INDEX idx_prt_hash ON password_reset_tokens (token_hash) WHERE used_at IS NULL;
