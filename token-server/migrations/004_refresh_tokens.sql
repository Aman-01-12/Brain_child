-- Migration 004: Refresh tokens table for two-token auth system (Phase B)
-- Stores SHA-256 hashes of opaque refresh tokens — raw tokens never enter the DB.
-- Family-based theft detection: if a revoked token is reused, the entire family is killed.

CREATE TABLE refresh_tokens (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,

    -- SHA-256 of the raw 32-byte token, stored as bytea.
    -- Raw token is returned to client only once and never persisted server-side.
    token_hash   BYTEA NOT NULL UNIQUE,

    -- All rotations of a single login session share a family_id.
    -- Reuse of any revoked token in a family triggers full family revocation.
    family_id    UUID NOT NULL,

    -- macOS hardware UUID (IOPlatformUUID) — soft device binding for anomaly detection.
    client_id    VARCHAR(100),

    issued_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at   TIMESTAMPTZ NOT NULL,

    -- NULL = active token. Timestamped = revoked. Row preserved for audit trail.
    revoked_at   TIMESTAMPTZ,

    -- Audit chain: each rotation stores the ID of the predecessor token it replaced.
    -- Traversing predecessor_id → ... walks the full rotation history for a session.
    predecessor_id  UUID REFERENCES refresh_tokens(id)
);

-- Primary lookup: hash-based search on every /auth/refresh call (active tokens only)
CREATE INDEX idx_rt_hash   ON refresh_tokens (token_hash) WHERE revoked_at IS NULL;

-- Logout: revoke all active tokens for a user
CREATE INDEX idx_rt_user   ON refresh_tokens (user_id) WHERE revoked_at IS NULL;

-- Theft detection: family-wide revocation (includes revoked rows)
CREATE INDEX idx_rt_family ON refresh_tokens (family_id);
