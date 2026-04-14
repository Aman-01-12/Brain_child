-- G10: Email change flow — requires verification of new email before swap

CREATE TABLE email_change_tokens (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    new_email   VARCHAR(254) NOT NULL,
    token_hash  BYTEA NOT NULL UNIQUE,
    expires_at  TIMESTAMPTZ NOT NULL,
    used_at     TIMESTAMPTZ
);

CREATE INDEX idx_ect_hash ON email_change_tokens (token_hash) WHERE used_at IS NULL;
