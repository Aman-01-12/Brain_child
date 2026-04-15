-- ASSERT: scheduled_meetings is a new table (created here). If this migration
-- is ever repurposed to ALTER an existing table, host_timezone must be added as
-- NULLABLE first, backfilled (e.g. SET host_timezone = 'UTC' or derived from
-- users.preferred_timezone via host_user_id), then ALTER COLUMN SET NOT NULL.

-- ---------------------------------------------------------------------------
-- Scheduled Meetings (Phase 11 — Scheduling & Productivity)
-- ---------------------------------------------------------------------------
CREATE TABLE scheduled_meetings (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    host_user_id        UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    title               VARCHAR(200) NOT NULL,
    description         TEXT,
    scheduled_at        TIMESTAMPTZ NOT NULL,
    duration_minutes    INT NOT NULL DEFAULT 60
                        CHECK (duration_minutes > 0 AND duration_minutes <= 1440),
    room_type           VARCHAR(20) NOT NULL DEFAULT 'call'
                        CHECK (room_type IN ('call', 'interview')),
    room_code           VARCHAR(6),
    password            VARCHAR(100),
    lobby_enabled       BOOLEAN NOT NULL DEFAULT FALSE,
    recurrence_rule     TEXT,
    host_timezone       VARCHAR(100) NOT NULL,
    status              VARCHAR(20) NOT NULL DEFAULT 'scheduled'
                        CHECK (status IN ('scheduled', 'cancelled', 'completed')),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Host's upcoming meetings (most common query)
CREATE INDEX idx_scheduled_meetings_host_upcoming
    ON scheduled_meetings (host_user_id, scheduled_at)
    WHERE status = 'scheduled';

-- Look up by room code (for join-by-code flow)
CREATE INDEX idx_scheduled_meetings_room_code
    ON scheduled_meetings (room_code)
    WHERE room_code IS NOT NULL AND status = 'scheduled';

-- Auto-update updated_at on row change
CREATE TRIGGER set_scheduled_meetings_updated_at
    BEFORE UPDATE ON scheduled_meetings
    FOR EACH ROW
    EXECUTE FUNCTION trigger_set_updated_at();

-- ---------------------------------------------------------------------------
-- Meeting Invitees (who was invited to a scheduled meeting)
-- ---------------------------------------------------------------------------
CREATE TABLE meeting_invitees (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    meeting_id          UUID NOT NULL REFERENCES scheduled_meetings(id) ON DELETE CASCADE,
    email               VARCHAR(255) NOT NULL,
    display_name        VARCHAR(100),
    status              VARCHAR(20) NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending', 'accepted', 'declined')),
    invited_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    responded_at        TIMESTAMPTZ
);

-- All invitees for a meeting
CREATE INDEX idx_meeting_invitees_meeting ON meeting_invitees (meeting_id);
-- A user's invitations (for "meetings I'm invited to" query)
CREATE INDEX idx_meeting_invitees_email ON meeting_invitees (email);
-- Prevent duplicate invitations
CREATE UNIQUE INDEX idx_meeting_invitees_unique ON meeting_invitees (meeting_id, email);
