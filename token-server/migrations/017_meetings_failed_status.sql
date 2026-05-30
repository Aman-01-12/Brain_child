-- ============================================================================
-- Migration 017: Add 'failed' status to meetings
--
-- Background: Before the LiveKit probe was added to POST /room/create and
-- POST /meetings/:id/start, a race existed where Redis and the DB were
-- written before verifying LiveKit was reachable. If LiveKit was offline the
-- call never started, leaving orphaned 'active' rows in meetings with no
-- ended_at and participants who never actually connected.
--
-- This migration:
--   1. Extends the meetings.status CHECK to allow 'failed'
--   2. Bulk-marks all existing phantom rows as 'failed':
--      - status='active' AND started_at older than the Redis TTL (25 h)
--        guarantees the Redis room has expired, confirming the call never ran
--   3. Extends the status CHECK on scheduled_meetings the same way
--      (the scheduled flow had the same bug)
-- ============================================================================

-- 1. Extend allowed status values on meetings
ALTER TABLE meetings
  DROP CONSTRAINT IF EXISTS meetings_status_check;

ALTER TABLE meetings
  ADD CONSTRAINT meetings_status_check
  CHECK (status IN ('active', 'ended', 'failed'));

-- 2. Mark stale phantom rows
--    Criteria: active + older than 25 h (Redis TTL is 24 h, so the room is
--    guaranteed gone) + no participant ever left (left_at is always NULL for
--    a meeting that never ran).
UPDATE meetings m
SET    status   = 'failed',
       ended_at = started_at   -- ended immediately — duration is 0
WHERE  m.status     = 'active'
  AND  m.started_at < NOW() - INTERVAL '25 hours'
  AND  NOT EXISTS (
         SELECT 1
         FROM   meeting_participants mp
         WHERE  mp.meeting_id = m.id
           AND  mp.left_at IS NOT NULL
       );

-- 3. Extend the scheduled_meetings status CHECK (same bug applied there too)
ALTER TABLE scheduled_meetings
  DROP CONSTRAINT IF EXISTS scheduled_meetings_status_check;

ALTER TABLE scheduled_meetings
  ADD CONSTRAINT scheduled_meetings_status_check
  CHECK (status IN ('scheduled', 'cancelled', 'completed', 'failed'));
