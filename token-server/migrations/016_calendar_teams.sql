-- Migration 016: Calendar OAuth + Team Management (Phase 11.2.4 / 11.2.5 / 11.4)
-- Adds encrypted OAuth refresh token columns to users table for Google Calendar
-- and Outlook Calendar sync.
-- Creates teams and team_members tables for team management.

-- ============================================================
-- 1. Calendar OAuth columns on users table
-- ============================================================

-- Google Calendar OAuth
ALTER TABLE users ADD COLUMN IF NOT EXISTS google_refresh_token TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS google_token_key_version SMALLINT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS google_reauth_required BOOLEAN NOT NULL DEFAULT false;

-- Outlook Calendar OAuth
ALTER TABLE users ADD COLUMN IF NOT EXISTS outlook_refresh_token TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS outlook_token_key_version SMALLINT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS outlook_reauth_required BOOLEAN NOT NULL DEFAULT false;

-- ============================================================
-- 2. Teams table
-- ============================================================

CREATE TABLE IF NOT EXISTS teams (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            VARCHAR(100) NOT NULL,
    owner_user_id   UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    description     VARCHAR(500),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_teams_owner ON teams(owner_user_id);

-- ============================================================
-- 3. Team members table
-- ============================================================

CREATE TABLE IF NOT EXISTS team_members (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    team_id         UUID NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
    user_id         UUID REFERENCES users(id) ON DELETE SET NULL,
    email           VARCHAR(254) NOT NULL,
    role            VARCHAR(20) NOT NULL DEFAULT 'member',  -- owner | admin | member
    status          VARCHAR(20) NOT NULL DEFAULT 'pending', -- pending | active | removed
    invited_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    joined_at       TIMESTAMPTZ,
    UNIQUE (team_id, email)
);

CREATE INDEX IF NOT EXISTS idx_team_members_team ON team_members(team_id);
CREATE INDEX IF NOT EXISTS idx_team_members_user ON team_members(user_id);
CREATE INDEX IF NOT EXISTS idx_team_members_email ON team_members(email);

-- ============================================================
-- 4. Triggers
-- ============================================================

CREATE OR REPLACE TRIGGER set_teams_updated_at
    BEFORE UPDATE ON teams
    FOR EACH ROW
    EXECUTE FUNCTION trigger_set_updated_at();
