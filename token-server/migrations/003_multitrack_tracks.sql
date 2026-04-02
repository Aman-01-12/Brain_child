-- Migration 003: Multi-track recording support
-- Adds a table to track individual participant egress sessions
-- under a parent recording_session (multi_track mode has N egress per session).
-- Also adds a manifest_url column to recording_sessions for the generated manifest.

-- Track per-participant egress in multi-track recordings
CREATE TABLE IF NOT EXISTS recording_tracks (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id            UUID NOT NULL REFERENCES recording_sessions(id) ON DELETE CASCADE,
    participant_identity  VARCHAR(100) NOT NULL,
    participant_name      VARCHAR(100),
    egress_id             VARCHAR(255) NOT NULL,
    storage_url           TEXT,
    duration_seconds      INTEGER,
    file_size_bytes       BIGINT,
    has_screen_share      BOOLEAN DEFAULT FALSE,
    status                VARCHAR(20) NOT NULL DEFAULT 'active'
                          CHECK (status IN ('active', 'finalizing', 'completed', 'failed')),
    created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_recording_tracks_session ON recording_tracks(session_id);
CREATE INDEX IF NOT EXISTS idx_recording_tracks_egress ON recording_tracks(egress_id);

-- Add manifest_url to recording_sessions for multi-track manifest JSON
ALTER TABLE recording_sessions ADD COLUMN IF NOT EXISTS manifest_url TEXT;
