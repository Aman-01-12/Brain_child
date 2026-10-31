-- Migration 023: Interview presence monitoring — PRESENCE MONITORING (provisional)
--
-- Candidate presence monitoring for secure interview mode. Three tables, because
-- the per-participant state is mutable, the events are immutable facts, and the
-- interviewer's notes are a different actor's artefact:
--
--   interview_presence_sessions  one row per (room_code, participant_identity);
--                                consent provenance, the armed operating point,
--                                the retention clock and the gap clock
--   interview_presence_events    the facts: six enum values, two timestamps, a
--                                duration, and the thresholds they were recorded
--                                under
--   interview_presence_notes     the interviewer's free-text judgement about ONE
--                                event; additive, encrypted, never destructive
--
-- WHAT THIS SCHEMA REFUSES TO STORE, deliberately and permanently:
--   * no score, index, percentage, rating, risk level or aggregate total — the
--     evaluation surface is per-type counts and durations only, and no column
--     here can carry anything else
--   * no emotion, affect, sentiment, mood, engagement, attention, focus,
--     confidence, stress, honesty, deception or personality field. Inferring
--     emotion from biometric data in a hiring context is a PROHIBITED practice
--     under EU AI Act Art. 5(1)(f) and binds this product as provider
--   * no gaze, iris, blink or eye-aspect-ratio field
--   * no head pose: 'head_off_axis' is deliberately absent from the event_type
--     CHECK below, so the database itself refuses a future-phase event smuggled
--     in early, and yaw/pitch/roll have no column
--   * no frame, crop, thumbnail, landmark, mesh, embedding or template column —
--     no pixels are ever transmitted to this server, in any form
--   * no email and no display name on the session row (see the note below)
--
-- Additive and forward-only (token-server/migrate.js has no down-migration
-- mechanism). IF NOT EXISTS throughout, per the 016/018/020 precedent.
--
-- ASSERT: requires `users` (001_initial_schema.sql), `meetings`
-- (001_initial_schema.sql) and the reusable `trigger_set_updated_at()` function
-- (001_initial_schema.sql) to already exist.

-- ============================================================
-- 1. interview_presence_sessions — the mutable per-participant state
--
--    NO EMAIL COLUMN AND NO DISPLAY NAME, deliberately: the candidate
--    copy/erasure (DSAR) endpoint is deferred, so storing a contact address
--    would be PII held for a purpose that does not yet exist. When that endpoint
--    is built, add candidate_email_enc TEXT + candidate_email_key_version
--    SMALLINT + a keyed-HMAC candidate_email_lookup CHAR(64) in a LATER
--    migration with a dedicated PRESENCE_EMAIL_HMAC_KEY.
-- ============================================================

CREATE TABLE IF NOT EXISTS interview_presence_sessions (
    id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    room_code              VARCHAR(6)   NOT NULL,              -- matches meetings.room_code
    participant_identity   VARCHAR(128) NOT NULL,              -- ephemeral client UUID; NOT a name, NOT an email

    -- ON DELETE CASCADE: `meetings` is the parent record. Without it these rows
    -- have no context and must go. Mirrors meeting_participants.meeting_id.
    -- Nullable because the /room/create meetings insert is best-effort.
    meeting_id             UUID REFERENCES meetings(id) ON DELETE CASCADE,

    -- ON DELETE SET NULL, NOT CASCADE: the candidate's record of what was
    -- collected about them — and the retention obligation over it — must outlive
    -- the recruiter's account deletion. The retention sweeper and the
    -- candidate's own erasure request are the only things that delete it.
    -- Mirrors audit_events.user_id and team_files.uploader_user_id.
    host_user_id           UUID REFERENCES users(id) ON DELETE SET NULL,

    -- ON DELETE SET NULL: candidates are usually guests, so this is nullable;
    -- when it is set, deleting the account must not destroy the retention clock.
    -- Mirrors meeting_participants.user_id.
    candidate_user_id      UUID REFERENCES users(id) ON DELETE SET NULL,

    -- Per-session state. FALSE is the fail-closed default: nothing is recorded
    -- until a candidate has actively granted consent.
    monitoring_enabled     BOOLEAN      NOT NULL DEFAULT FALSE,
    -- 'not_offered' is the EU / under-18 route: the monitored option is never
    -- shown, so there is no decision to record.
    consent_state          VARCHAR(20)  NOT NULL DEFAULT 'pending'
                             CHECK (consent_state IN ('pending','granted','declined','not_offered')),
    consent_granted_at     TIMESTAMPTZ,
    consent_declined_at    TIMESTAMPTZ,
    consent_version        VARCHAR(32),                        -- pins WHICH notice text was shown

    -- Why monitoring was off, recorded with the row rather than inferred later.
    policy_region_eu       BOOLEAN      NOT NULL DEFAULT FALSE,
    policy_under_18        BOOLEAN      NOT NULL DEFAULT FALSE,
    multiple_faces_enabled BOOLEAN      NOT NULL DEFAULT FALSE,

    -- The operating point, so a stored event is reconstructible.
    detector_version       TEXT         NOT NULL,
    thresholds             JSONB        NOT NULL,

    started_at             TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    last_report_at         TIMESTAMPTZ,                        -- the monitoring_gap clock
    ended_at               TIMESTAMPTZ,                        -- set by the stale-session closer

    -- Per-row retention clock, stamped at insert from PRESENCE_EVENT_RETENTION_DAYS.
    -- A later env change produces new clocks on NEW rows and never rewrites old ones.
    purge_after            TIMESTAMPTZ  NOT NULL,

    created_at             TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at             TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- One session per identity per room — the ingest upsert's conflict target.
CREATE UNIQUE INDEX IF NOT EXISTS idx_ips_room_identity
    ON interview_presence_sessions (room_code, participant_identity);
-- The retention sweeper's only query.
CREATE INDEX IF NOT EXISTS idx_ips_purge_due
    ON interview_presence_sessions (purge_after);
-- The stale-session closer's only query.
CREATE INDEX IF NOT EXISTS idx_ips_stale
    ON interview_presence_sessions (last_report_at)
    WHERE monitoring_enabled = TRUE AND ended_at IS NULL;

-- updated_at maintenance (house convention). Sessions are the only mutable
-- table of the three, so this is the only trigger in this migration.
DROP TRIGGER IF EXISTS set_interview_presence_sessions_updated_at ON interview_presence_sessions;
CREATE TRIGGER set_interview_presence_sessions_updated_at
    BEFORE UPDATE ON interview_presence_sessions
    FOR EACH ROW
    EXECUTE FUNCTION trigger_set_updated_at();

-- ============================================================
-- 2. interview_presence_events — the facts
--
--    Append-only by convention in application code (there is no UPDATE path),
--    but NOT by a database trigger: unlike audit_events, the retention sweeper
--    must DELETE these rows to honour the retention promise, and a no-delete
--    trigger would make that obligation unsatisfiable.
--
--    Not encrypted, deliberately: a row is one of six enum values, two
--    timestamps and an integer. Encrypting it would break the sweeper's and the
--    timeline's index usage for no privacy gain.
-- ============================================================

CREATE TABLE IF NOT EXISTS interview_presence_events (
    id               BIGSERIAL PRIMARY KEY,                    -- monotonic timeline ordering key

    -- ON DELETE CASCADE: an event without its session has no thresholds, no
    -- consent provenance and no retention clock, so it must never survive it.
    -- This is also what makes a candidate erasure a single DELETE.
    session_id       UUID        NOT NULL REFERENCES interview_presence_sessions(id) ON DELETE CASCADE,

    -- 'head_off_axis' IS DELIBERATELY ABSENT. Head pose is out of scope and not
    -- collected anywhere; the database refuses it even if a future caller tries.
    -- VARCHAR + CHECK, not a Postgres ENUM type (none exists in this schema).
    event_type       VARCHAR(32) NOT NULL
                       CHECK (event_type IN ('face_absent',
                                             'multiple_faces',
                                             'image_quality_insufficient',
                                             'camera_disabled',
                                             'camera_enabled',
                                             'monitoring_gap')),

    started_at       TIMESTAMPTZ NOT NULL,
    ended_at         TIMESTAMPTZ,                              -- = started_at for instantaneous camera transitions
    duration_ms      INTEGER     NOT NULL DEFAULT 0 CHECK (duration_ms >= 0),

    -- The operating point in force for THIS event, stamped by the SERVER from
    -- the session's armed config and NEVER from the client payload: a client
    -- cannot rewrite the operating point of its own record, and a later
    -- threshold change produces new rows going forward, never different rows
    -- looking back.
    detector_version TEXT        NOT NULL,
    thresholds       JSONB       NOT NULL,

    -- 'server' for monitoring_gap (which a client may neither forge nor
    -- suppress), 'client' for everything else. Provenance is explicit.
    source           VARCHAR(10) NOT NULL DEFAULT 'client' CHECK (source IN ('client','server')),

    purge_after      TIMESTAMPTZ NOT NULL,                     -- per-row retention clock
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- The timeline's only query.
CREATE INDEX IF NOT EXISTS idx_ipe_session_time
    ON interview_presence_events (session_id, started_at);
-- The sweeper's only query.
CREATE INDEX IF NOT EXISTS idx_ipe_purge_due
    ON interview_presence_events (purge_after);
-- The per-type summary's GROUP BY.
CREATE INDEX IF NOT EXISTS idx_ipe_session_type
    ON interview_presence_events (session_id, event_type);

-- ============================================================
-- 3. interview_presence_notes — the interviewer's judgement
--
--    Additive and never destructive: a note annotates exactly one event and
--    nothing in this feature acts automatically on anything.
-- ============================================================

CREATE TABLE IF NOT EXISTS interview_presence_notes (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- ON DELETE CASCADE: a note annotates exactly one event; orphaning it would
    -- leave a human judgement with nothing to check it against.
    event_id            BIGINT       NOT NULL REFERENCES interview_presence_events(id) ON DELETE CASCADE,

    -- ON DELETE SET NULL so the note survives the author's account deletion.
    -- Non-null is enforced at the API layer, where the moderator check
    -- guarantees an authenticated moderator wrote it.
    author_user_id      UUID REFERENCES users(id) ON DELETE SET NULL,
    -- Denormalised snapshot (the team_messages.sender_name precedent) so the
    -- note still says who wrote it after author_user_id goes null.
    author_display_name VARCHAR(100) NOT NULL,

    -- Encrypted via token-server/crypto.js, format v{N}:{iv}:{tag}:{ct}. This is
    -- the one field in the feature that warrants encryption: a free-text human
    -- judgement about a named person is the most sensitive string it produces.
    -- The note endpoint FAILS CLOSED (500 ENCRYPTION_UNAVAILABLE) rather than
    -- storing plaintext when no key is configured.
    note_text_enc       TEXT         NOT NULL,
    -- Companion column, the migration-016 convention (google_refresh_token +
    -- google_token_key_version). Informational / for rotation sweeps, since the
    -- version is also read from the blob prefix at decrypt time.
    note_key_version    SMALLINT     NOT NULL,

    created_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_ipn_event
    ON interview_presence_notes (event_id, created_at);
