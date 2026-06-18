-- ---------------------------------------------------------------------------
-- 021_recording_max_duration.sql
--
-- Per-recording hard cap (seconds), set at start from the recording account's
-- remaining quota. A server-side sweeper stops egresses whose elapsed time exceeds
-- this cap, preventing a single recording from overrunning the quota (and the
-- operator's egress/storage cost) when the client under-estimates duration. (F1)
-- ---------------------------------------------------------------------------
ALTER TABLE recording_sessions
    ADD COLUMN IF NOT EXISTS max_duration_seconds INTEGER;
