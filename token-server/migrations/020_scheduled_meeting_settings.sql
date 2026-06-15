-- 020_scheduled_meeting_settings.sql
--
-- Scheduled meetings previously stored only password + lobby_enabled; the
-- host's remaining meeting settings (mute on join, camera off on join, chat /
-- sharing permissions, …) silently fell back to server defaults when the
-- meeting started. Store a settings snapshot taken at SCHEDULE time so
-- /meetings/:id/start can apply it to the room hash regardless of who arrives
-- first (host or invitee).
--
-- JSONB keys mirror the /room/create settings body: muteOnJoin,
-- cameraOffOnJoin, joinBeforeHost, allowUnmuting, chatPermissions,
-- sharingPermissions, shareConflictPolicy. Empty object = legacy rows /
-- clients that didn't send settings → start falls back to defaults exactly
-- as before this migration.

ALTER TABLE scheduled_meetings
    ADD COLUMN IF NOT EXISTS settings JSONB NOT NULL DEFAULT '{}';
