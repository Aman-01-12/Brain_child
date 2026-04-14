-- G4: Absolute session hard cutoff
-- G11: Session listing (last_used_at tracking)

ALTER TABLE refresh_tokens
  ADD COLUMN absolute_expires_at TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '30 days'),
  ADD COLUMN last_used_at        TIMESTAMPTZ;

-- Backfill: replace the NOW()-relative DEFAULT with the correct issued_at-relative
-- value for all existing rows.
UPDATE refresh_tokens
SET absolute_expires_at = issued_at + INTERVAL '30 days';

-- Tighten: remove the DEFAULT so the application must always supply an explicit
-- value; NOT NULL remains as DB-level enforcement.
ALTER TABLE refresh_tokens
  ALTER COLUMN absolute_expires_at DROP DEFAULT;
