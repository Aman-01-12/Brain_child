-- ============================================================================
-- Migration 002: Recording Sessions
-- Phase 10C [G10.3]
--
-- Recording metering tables for cloud and local recording:
--   recording_sessions       — each recording attempt (local, cloud, multi_track)
--   recording_download_audit — audit trail for presigned URL downloads
--
-- Also adds metering columns to the existing users table.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Users — recording metering columns
-- ---------------------------------------------------------------------------
ALTER TABLE users ADD COLUMN IF NOT EXISTS recording_minutes_used INTEGER NOT NULL DEFAULT 0;
ALTER TABLE users ADD COLUMN IF NOT EXISTS recording_quota_minutes INTEGER NOT NULL DEFAULT 0;
-- Free: 0 (no cloud), Pro: 600 (10hrs), Hiring: 1200 (20hrs)
-- Quota is set at registration via tier or updated on subscription change.

-- ---------------------------------------------------------------------------
-- Recording sessions
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS recording_sessions (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id           UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    room_name         VARCHAR(255) NOT NULL,
    room_code         VARCHAR(6),
    egress_id         VARCHAR(255),             -- LiveKit egress ID (cloud/multi-track only)
    recording_mode    VARCHAR(50) NOT NULL
                      CHECK (recording_mode IN ('local_composed', 'cloud_composed', 'multi_track')),
    started_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ended_at          TIMESTAMPTZ,
    duration_seconds  INTEGER,
    file_size_bytes   BIGINT,
    storage_url       TEXT,                      -- S3 URL (cloud only)
    watermarked       BOOLEAN NOT NULL DEFAULT false,
    status            VARCHAR(20) NOT NULL DEFAULT 'active'
                      CHECK (status IN ('active', 'finalizing', 'completed', 'failed')),
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Only one active recording per room at a time
CREATE UNIQUE INDEX IF NOT EXISTS idx_recording_sessions_active_room
    ON recording_sessions (room_name) WHERE status = 'active';

-- Lookup by egress ID (webhook handler)
CREATE INDEX IF NOT EXISTS idx_recording_sessions_egress
    ON recording_sessions (egress_id) WHERE egress_id IS NOT NULL;

-- Lookup by user (recording list)
CREATE INDEX IF NOT EXISTS idx_recording_sessions_user
    ON recording_sessions (user_id, created_at DESC);

-- ---------------------------------------------------------------------------
-- Recording download audit
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS recording_download_audit (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id      UUID NOT NULL REFERENCES recording_sessions(id) ON DELETE CASCADE,
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    requested_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ip_address      INET
);

CREATE INDEX IF NOT EXISTS idx_download_audit_session
    ON recording_download_audit (session_id);
CREATE INDEX IF NOT EXISTS idx_download_audit_user
    ON recording_download_audit (user_id, requested_at);
