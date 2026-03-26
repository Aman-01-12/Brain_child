-- ============================================================================
-- Migration 001: Initial Schema
-- Phase 6.2 [G6.2.4]
--
-- Foundation tables for Inter:
--   users               — authenticated user accounts
--   meetings            — persistent room/meeting history
--   meeting_participants — join/leave log for each meeting
--
-- Design decisions:
--   - UUIDs for all PKs (no sequential leaking)
--   - Anonymous guests have NULL user_id in meeting_participants
--   - Tier system: free | pro | hiring (extensible via CHECK)
--   - Room type: call | interview (extensible)
--   - Indexes on foreign keys + common query patterns
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Users (authentication base)
-- ---------------------------------------------------------------------------
CREATE TABLE users (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email           VARCHAR(255) UNIQUE NOT NULL,
    display_name    VARCHAR(100) NOT NULL,
    password_hash   VARCHAR(255) NOT NULL,
    tier            VARCHAR(20) NOT NULL DEFAULT 'free'
                    CHECK (tier IN ('free', 'pro', 'hiring')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index for login lookups
CREATE INDEX idx_users_email ON users (email);

-- ---------------------------------------------------------------------------
-- Meetings (persistent room history)
-- ---------------------------------------------------------------------------
CREATE TABLE meetings (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    host_user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    room_code       VARCHAR(6) NOT NULL,
    room_name       VARCHAR(100) NOT NULL,
    room_type       VARCHAR(20) NOT NULL DEFAULT 'call'
                    CHECK (room_type IN ('call', 'interview')),
    status          VARCHAR(20) NOT NULL DEFAULT 'active'
                    CHECK (status IN ('active', 'ended')),
    started_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ended_at        TIMESTAMPTZ,
    max_participants INT NOT NULL DEFAULT 50
);

-- Index for looking up a user's meeting history
CREATE INDEX idx_meetings_host ON meetings (host_user_id);
-- Index for looking up active meetings by room code
CREATE INDEX idx_meetings_room_code ON meetings (room_code) WHERE status = 'active';

-- ---------------------------------------------------------------------------
-- Meeting participants (join/leave log)
-- ---------------------------------------------------------------------------
CREATE TABLE meeting_participants (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    meeting_id      UUID NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    user_id         UUID REFERENCES users(id) ON DELETE SET NULL,  -- NULL for anonymous guests
    identity        VARCHAR(100) NOT NULL,
    display_name    VARCHAR(100) NOT NULL,
    role            VARCHAR(20) NOT NULL DEFAULT 'participant'
                    CHECK (role IN ('host', 'co-host', 'presenter', 'participant',
                                    'interviewer', 'interviewee')),
    joined_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    left_at         TIMESTAMPTZ
);

-- Index for looking up participants in a meeting
CREATE INDEX idx_participants_meeting ON meeting_participants (meeting_id);
-- Index for looking up a user's participation history
CREATE INDEX idx_participants_user ON meeting_participants (user_id) WHERE user_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- updated_at trigger function (reusable)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trigger_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply to users table
CREATE TRIGGER set_users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW
    EXECUTE FUNCTION trigger_set_updated_at();
