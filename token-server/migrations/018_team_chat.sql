-- Migration 018: Team Chat — group messaging + file sharing (Phase 11.5 / Task 3)
-- Adds persistent per-team chat: messages, file metadata (bytes live in S3),
-- and per-user read cursors for in-app unread badges.
--
-- Design (see docs/superpowers/specs/2026-06-11-teams-chat-design.md):
--   - Persistence is the source of truth; the Socket.IO fan-out is best-effort.
--   - team_messages.id (BIGSERIAL) is the monotonic per-team ordering key.
--   - Read cursor is an idempotent set-to-max of the last-seen message id.
--   - Builds additively on migration 016 (teams, team_members).

-- ============================================================
-- 1. Team files — metadata only; file bytes are stored in S3
--    under a team-prefixed key (team-files/<teamId>/<uuid>).
--    Defined BEFORE team_messages because team_messages.file_id
--    references this table.
-- ============================================================

CREATE TABLE IF NOT EXISTS team_files (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    team_id           UUID NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
    uploader_user_id  UUID REFERENCES users(id) ON DELETE SET NULL,
    s3_key            TEXT NOT NULL,                  -- bare S3 key, never sent to clients raw
    original_name     VARCHAR(255) NOT NULL,          -- sanitized display filename
    mime_type         VARCHAR(255) NOT NULL,          -- magic-byte detected (not client-supplied)
    size_bytes        BIGINT NOT NULL,
    is_image          BOOLEAN NOT NULL DEFAULT false, -- set only from detected MIME
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_team_files_team ON team_files(team_id);

-- ============================================================
-- 2. Team messages — append-only; BIGSERIAL id orders the team.
-- ============================================================

CREATE TABLE IF NOT EXISTS team_messages (
    id                BIGSERIAL PRIMARY KEY,
    team_id           UUID NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
    sender_user_id    UUID REFERENCES users(id) ON DELETE SET NULL,
    sender_name       VARCHAR(100) NOT NULL,          -- denormalized snapshot at send time
    kind              VARCHAR(16)  NOT NULL DEFAULT 'text', -- 'text' | 'file'
    body              TEXT,                            -- <= 4000 chars; NULL for file-only messages
    file_id           UUID REFERENCES team_files(id) ON DELETE SET NULL,
    idempotency_key   VARCHAR(255),                    -- per-(team,sender) retry dedup
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Primary access pattern: latest-first history per team, and unread COUNT(*).
CREATE INDEX IF NOT EXISTS idx_team_messages_team_id ON team_messages(team_id, id DESC);

-- Defense-in-depth dedup of retried sends (idempotency middleware is the first layer).
CREATE UNIQUE INDEX IF NOT EXISTS uq_team_messages_idem
    ON team_messages(team_id, sender_user_id, idempotency_key)
    WHERE idempotency_key IS NOT NULL;

-- ============================================================
-- 3. Read cursors — per-(user, team) last-seen message id.
--    Updated as set-to-max so it is idempotent and lost-update safe.
-- ============================================================

CREATE TABLE IF NOT EXISTS team_read_cursors (
    team_id              UUID NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
    user_id              UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    last_read_message_id BIGINT NOT NULL DEFAULT 0,
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (team_id, user_id)
);
