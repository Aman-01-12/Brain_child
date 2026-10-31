// ============================================================================
// presence.js — PRESENCE MONITORING (provisional)
//
// The /presence router: consent, event ingest, the moderator-authorised
// timeline, the interviewer's note, and export. Dependency-injected (the
// recordingQuota.js / joinGuards.js house pattern) so index.js stays the only
// place that knows about Redis key helpers, and so this file is deletable in one
// step. See .agents/tasks/presence-monitoring/REMOVAL.md.
//
// WHAT THIS ROUTER WILL NEVER DO:
//   * produce a score, index, percentage, rating, risk level, aggregate total,
//     or any comparison between candidates or sessions — the evaluation surface
//     is per-type counts and durations, full stop
//   * infer or report emotion, affect, sentiment, mood, engagement, attention,
//     focus, confidence, stress, honesty, deception or personality. In a hiring
//     context that is a PROHIBITED practice under EU AI Act Art. 5(1)(f)
//   * accept a frame, crop, thumbnail, landmark set or embedding (see
//     presenceEvents.js FORBIDDEN_KEYS — rejected, never stripped)
//   * take any automated action: nothing here warns, interrupts, ends, ranks or
//     propagates anything. The interviewer adjudicates, by hand, as they already
//     do.
//
// Authorisation model:
//   * candidate paths (consent, ingest) authenticate with the room's Leave-Token
//     for (code, identity), compared in constant time — the /room/leave precedent
//   * moderator paths (timeline, note, export) require a real account AND
//     validateModerator(code, callerIdentity, userId), which cross-checks the
//     body/query-supplied callerIdentity against the room's identity->userId
//     binding. That cross-check is what stops an authenticated participant from
//     passing the host's peer-visible identity to read another candidate's rows
//   * the tier gate reads the room's SNAPSHOTTED hostTier, so the host's plan
//     decides and the candidate's own plan is irrelevant
// ============================================================================

const express = require('express');
const presenceEvents = require('./presenceEvents');

// Which event types the interviewer's live chip may surface mid-interview.
// Computed SERVER-side so a patched client cannot widen what is surfaced live.
const LIVE_SURFACEABLE = Object.freeze(['multiple_faces', 'face_absent']);

const MAX_NOTE_LENGTH = 2000;
const MIN_NOTE_LENGTH = 10;
const MAX_TIMELINE_EVENTS = 2000;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function createPresenceRouter({
  db,
  redis,
  crypto,              // token-server/crypto.js — versioned AES-256-GCM
  tiers,
  config,              // presenceConfig
  auditLog,            // auth.auditLog — the ONLY audit_events writer
  requireAuth,         // auth.requireAuth
  validateModerator,
  getRoomData,
  // eslint-disable-next-line no-unused-vars
  roomKey,             // part of the injected contract; room state is read through getRoomData
  roomLeaveTokenKey,
  constantTimeEqual,
  sanitizeFilename,
  logger = console,
}) {
  const router = express.Router();

  // -------------------------------------------------------------------------
  // requirePresenceFeature — THE master flag, consulted here and in
  // resolvePresenceArming(), nowhere else. 404 (not 403) because when the
  // feature is off this surface does not exist.
  // -------------------------------------------------------------------------
  router.use(function requirePresenceFeature(req, res, next) {
    if (!config.isFeatureEnabled()) {
      return res.status(404).json({ error: 'Not found', code: 'PRESENCE_DISABLED' });
    }
    next();
  });

  // -------------------------------------------------------------------------
  // Rate limiting
  //
  // Same Redis INCR + EXPIRE shape as rateLimitRoomAction, plus a Retry-After
  // header and the RATE_LIMITED code string (new here: no existing limiter
  // emits a code). Keyed on the authenticated userId, else on
  // (roomCode, identity) for the leave-token paths — NOT on bare IP, because a
  // corporate NAT would otherwise share one candidate's budget.
  //
  // On a Redis error these endpoints return 503 PRESENCE_UNAVAILABLE instead of
  // failing open, which DIVERGES from the surrounding fail-open rate-limit
  // convention. The reason: every one of these handlers already needs Redis for
  // the room data and the leave token, so there is nothing to fail open to, and
  // an unmetered flood of behavioural-record writes is the worse failure.
  // -------------------------------------------------------------------------
  function principalFor(req) {
    if (req.user && req.user.userId != null) return `u:${req.user.userId}`;
    const code = String((req.body && req.body.roomCode) || (req.params && req.params.code) || '')
      .toUpperCase().slice(0, 16);
    const identity = String((req.body && req.body.identity) || (req.params && req.params.identity) || '')
      .slice(0, 128);
    return `lt:${code}:${identity}`;
  }

  function makePresenceRateLimiter(action, max, windowSec) {
    return async (req, res, next) => {
      const key = `ratelimit:${action}:${principalFor(req)}`;
      try {
        const count = await redis.incr(key);
        if (count === 1) await redis.expire(key, windowSec);
        if (count > max) {
          const ttl = await redis.ttl(key);
          res.setHeader('Retry-After', String(ttl > 0 ? ttl : windowSec));
          return res.status(429).json({
            error: 'Too many requests. Please slow down and try again.',
            code: 'RATE_LIMITED',
          });
        }
      } catch (err) {
        logger.error(`[presence rate limit] Redis error (action=${action}): ${err.message}`);
        return res.status(503).json({
          error: 'Presence monitoring is temporarily unavailable.',
          code: 'PRESENCE_UNAVAILABLE',
        });
      }
      next();
    };
  }

  // -------------------------------------------------------------------------
  // Shared guards
  // -------------------------------------------------------------------------

  function unavailable(res, where, err) {
    logger.error(`[presence] ${where} failed: ${err.message}`);
    return res.status(503).json({
      error: 'Presence monitoring is temporarily unavailable.',
      code: 'PRESENCE_UNAVAILABLE',
    });
  }

  /// Candidate authentication: the room's Leave-Token for exactly this
  /// (code, identity), compared in constant time. The same secret /room/leave
  /// uses, so a participant proves they are the participant without needing an
  /// account — candidates are usually guests.
  async function requireLeaveToken(req, res, next) {
    const code = String((req.body && req.body.roomCode) || '').toUpperCase();
    const identity = String((req.body && req.body.identity) || '');
    const supplied = req.get('Leave-Token');

    if (!code || !identity || !supplied) {
      return res.status(403).json({ error: 'Not authorised for this session.', code: 'PRESENCE_UNAUTHORIZED' });
    }
    let stored;
    try {
      stored = await redis.get(roomLeaveTokenKey(code, identity));
    } catch (err) {
      return unavailable(res, 'leave-token lookup', err);
    }
    if (!stored || !constantTimeEqual(supplied, stored)) {
      logger.warn(`[presence] leave-token mismatch: code=${code} identity=${identity}`);
      return res.status(403).json({ error: 'Not authorised for this session.', code: 'PRESENCE_UNAUTHORIZED' });
    }
    req.presenceCode = code;
    req.presenceIdentity = identity;
    next();
  }

  /// Load the room hash and enforce the tier gate, then the arming state.
  ///
  /// Tier gating is the inline tiers.isFeatureAllowed(...) form used by
  /// /room/create and /meetings/schedule — NOT auth.requireTier, which the
  /// interview paths do not use. The tier read is the room's snapshotted
  /// hostTier: monitoring rides the existing hostInterview -> hiring
  /// entitlement, and no new FEATURES key is introduced.
  async function loadArmedRoom(req, res, next) {
    const code = req.presenceCode;
    let roomData;
    try {
      roomData = await getRoomData(code);
    } catch (err) {
      return unavailable(res, 'room lookup', err);
    }
    if (!roomData) {
      return res.status(404).json({ error: 'No presence session for this room.', code: 'PRESENCE_SESSION_NOT_FOUND' });
    }
    if (!tiers.isFeatureAllowed(roomData.hostTier, tiers.FEATURES.HOST_INTERVIEW)) {
      return res.status(403).json({
        error: 'Presence monitoring requires a hiring plan.',
        code: 'INSUFFICIENT_TIER',
        currentTier: roomData.hostTier || 'free',
        requiredTier: tiers.minTierForFeature(tiers.FEATURES.HOST_INTERVIEW),
      });
    }
    if (roomData.presenceMonitoringArmed !== 'true') {
      return res.status(409).json({
        error: 'Presence monitoring was not enabled for this interview.',
        code: 'PRESENCE_MONITORING_NOT_ARMED',
      });
    }
    req.presenceRoom = roomData;
    next();
  }

  /// Moderator authorisation for the read paths. requireAuth has already run, so
  /// req.user is populated; validateModerator cross-checks the supplied
  /// callerIdentity against the room's identity->userId binding and then
  /// requires a moderator role. Fail closed on everything.
  async function requireModerator(req, res, next) {
    const code = String(req.params.code || '').toUpperCase();
    const callerIdentity = String(
      (req.body && req.body.callerIdentity) || (req.query && req.query.callerIdentity) || ''
    );
    if (!code || !callerIdentity) {
      return res.status(403).json({ error: 'Moderator role required.', code: 'PRESENCE_FORBIDDEN' });
    }
    let roomData;
    try {
      roomData = await getRoomData(code);
    } catch (err) {
      return unavailable(res, 'room lookup', err);
    }
    if (!roomData) {
      return res.status(404).json({ error: 'No presence session for this room.', code: 'PRESENCE_SESSION_NOT_FOUND' });
    }
    if (!tiers.isFeatureAllowed(roomData.hostTier, tiers.FEATURES.HOST_INTERVIEW)) {
      return res.status(403).json({
        error: 'Presence monitoring requires a hiring plan.',
        code: 'INSUFFICIENT_TIER',
        currentTier: roomData.hostTier || 'free',
        requiredTier: tiers.minTierForFeature(tiers.FEATURES.HOST_INTERVIEW),
      });
    }
    let verdict;
    try {
      verdict = await validateModerator(code, callerIdentity, req.user.userId);
    } catch (err) {
      return unavailable(res, 'moderator check', err);
    }
    if (!verdict || !verdict.valid) {
      logger.warn(`[presence] moderator check denied: code=${code} caller=${callerIdentity}`);
      return res.status(403).json({ error: 'Moderator role required.', code: 'PRESENCE_FORBIDDEN' });
    }
    req.presenceCode = code;
    req.presenceIdentity = String(req.params.identity || '');
    req.presenceRoom = roomData;
    next();
  }

  // -------------------------------------------------------------------------
  // Session helpers
  // -------------------------------------------------------------------------

  function parseThresholds(roomData) {
    if (roomData && typeof roomData.presenceThresholds === 'string' && roomData.presenceThresholds.length > 0) {
      try {
        const parsed = JSON.parse(roomData.presenceThresholds);
        if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) return parsed;
      } catch (_) { /* fall through to the live snapshot */ }
    }
    return config.thresholdSnapshot();
  }

  function detectorVersionFor(roomData) {
    const v = roomData && roomData.presenceDetectorVersion;
    return (typeof v === 'string' && v.length > 0) ? v : config.DETECTOR_VERSION;
  }

  async function loadSession(code, identity) {
    const { rows } = await db.query(
      `SELECT id, monitoring_enabled, consent_state, consent_version,
              policy_region_eu, policy_under_18, multiple_faces_enabled,
              detector_version, thresholds,
              started_at, last_report_at, ended_at
       FROM interview_presence_sessions
       WHERE room_code = $1 AND participant_identity = $2`,
      [code, identity]
    );
    return rows[0] || null;
  }

  /// The host's account id, read from the meetings row the room hash points at.
  /// Best-effort: a guest-hosted or DB-less room simply has no host id.
  async function hostUserIdFor(roomData) {
    const meetingId = roomData && roomData.meetingId;
    if (!meetingId || !UUID_RE.test(String(meetingId))) return { meetingId: null, hostUserId: null };
    try {
      const { rows } = await db.query('SELECT id, host_user_id FROM meetings WHERE id = $1', [meetingId]);
      if (!rows[0]) return { meetingId: null, hostUserId: null };
      return { meetingId: rows[0].id, hostUserId: rows[0].host_user_id || null };
    } catch (err) {
      logger.error(`[presence] meeting lookup failed: ${err.message}`);
      return { meetingId: null, hostUserId: null };
    }
  }

  // =========================================================================
  // POST /presence/consent
  // Body: { roomCode, identity, decision: 'grant' | 'decline' }
  // Header: Leave-Token
  //
  // Declining ALWAYS joins with monitoring off and is never asked for a reason.
  // There is no blocking variant of this consent, not even as a room setting:
  // consent that cannot be refused is not consent, and this is also the
  // disability-accommodation path.
  // =========================================================================
  router.post('/consent',
    makePresenceRateLimiter('presence-consent', 10, 600),
    requireLeaveToken,
    loadArmedRoom,
    async (req, res) => {
      const decision = req.body && req.body.decision;
      if (decision !== 'grant' && decision !== 'decline') {
        return res.status(400).json({
          error: "decision must be 'grant' or 'decline'.",
          code: 'PRESENCE_PAYLOAD_INVALID',
        });
      }

      const code = req.presenceCode;
      const identity = req.presenceIdentity;
      const roomData = req.presenceRoom;
      const granted = decision === 'grant';

      try {
        const { meetingId, hostUserId } = await hostUserIdFor(roomData);
        const thresholds = parseThresholds(roomData);
        const detectorVersion = detectorVersionFor(roomData);
        const regionEU = roomData.presenceRegionEU === 'true';
        const under18 = roomData.presenceUnder18 === 'true';
        // Fail closed: an EU-resident or under-18 candidate is never monitored
        // even if a grant somehow reaches this endpoint.
        const monitoringEnabled = granted && !regionEU && !under18;

        const { rows } = await db.query(
          `INSERT INTO interview_presence_sessions
             (room_code, participant_identity, meeting_id, host_user_id, candidate_user_id,
              monitoring_enabled, consent_state, consent_granted_at, consent_declined_at,
              consent_version, policy_region_eu, policy_under_18, multiple_faces_enabled,
              detector_version, thresholds, last_report_at, purge_after)
           VALUES ($1, $2, $3, $4, $5,
                   $6, $7, $8, $9,
                   $10, $11, $12, $13,
                   $14, $15::jsonb, $16, NOW() + ($17::int * INTERVAL '1 day'))
           ON CONFLICT (room_code, participant_identity) DO UPDATE SET
              monitoring_enabled  = EXCLUDED.monitoring_enabled,
              consent_state       = EXCLUDED.consent_state,
              consent_granted_at  = COALESCE(interview_presence_sessions.consent_granted_at,
                                             EXCLUDED.consent_granted_at),
              consent_declined_at = COALESCE(EXCLUDED.consent_declined_at,
                                             interview_presence_sessions.consent_declined_at),
              consent_version     = EXCLUDED.consent_version,
              last_report_at      = COALESCE(EXCLUDED.last_report_at,
                                             interview_presence_sessions.last_report_at),
              ended_at            = NULL
           RETURNING id, monitoring_enabled, consent_state`,
          [
            code, identity, meetingId, hostUserId,
            (req.user && req.user.userId) || null,
            monitoringEnabled,
            granted ? 'granted' : 'declined',
            granted ? new Date().toISOString() : null,
            granted ? null : new Date().toISOString(),
            config.CONSENT_VERSION, regionEU, under18,
            roomData.presenceMultipleFacesEnabled === 'true',
            detectorVersion, JSON.stringify(thresholds),
            monitoringEnabled ? new Date().toISOString() : null,
            config.retentionDays(),
          ]
        );

        const row = rows[0];
        // Audit: never awaited, no note text, no email, no thresholds as free
        // text. userId is null for a guest candidate and the ephemeral identity
        // lives in the metadata — what audit_events.user_id is designed for.
        auditLog(
          (req.user && req.user.userId) || null,
          granted ? 'presence_consent_granted' : 'presence_consent_declined',
          req.ip,
          { roomCode: code, identity, consentState: row.consent_state }
        );
        auditLog(
          (req.user && req.user.userId) || null,
          monitoringEnabled ? 'presence_monitoring_enabled' : 'presence_monitoring_disabled',
          req.ip,
          { roomCode: code, identity, policyRegionEU: regionEU, policyUnder18: under18 }
        );

        return res.json({
          monitoringEnabled: row.monitoring_enabled === true,
          consentState: row.consent_state,
          consentVersion: config.CONSENT_VERSION,
          retentionDays: config.retentionDays(),
          rightsContact: config.rightsContact(),
        });
      } catch (err) {
        return unavailable(res, 'consent write', err);
      }
    }
  );

  // =========================================================================
  // POST /presence/events
  // Body: { roomCode, identity, events: [{ eventType, startedAt, endedAt,
  //                                        durationMs, detectorVersion? }] }
  // Header: Leave-Token
  //
  // An empty events array is a valid heartbeat ("still here, nothing to
  // report"). That is what makes real silence meaningful: when nothing arrives
  // for PRESENCE_GAP_SECONDS the SERVER records a monitoring_gap, which a client
  // can neither forge nor suppress.
  // =========================================================================
  router.post('/events',
    makePresenceRateLimiter('presence-events', 30, 60),
    requireLeaveToken,
    loadArmedRoom,
    async (req, res) => {
      const code = req.presenceCode;
      const identity = req.presenceIdentity;
      const roomData = req.presenceRoom;

      const verdict = presenceEvents.validateEventBatch(req.body, {
        multipleFacesEnabled: roomData.presenceMultipleFacesEnabled === 'true',
      });
      if (!verdict.ok) {
        const payload = { error: verdict.error, code: verdict.code };
        if (verdict.field !== undefined) payload.field = verdict.field;
        return res.status(verdict.status).json(payload);
      }

      try {
        const session = await loadSession(code, identity);
        if (!session) {
          return res.status(404).json({
            error: 'No presence session for this participant.',
            code: 'PRESENCE_SESSION_NOT_FOUND',
          });
        }
        if (session.consent_state !== 'granted' || session.monitoring_enabled !== true) {
          return res.status(409).json({
            error: 'Presence monitoring is not active for this participant.',
            code: 'PRESENCE_CONSENT_REQUIRED',
          });
        }

        const retention = config.retentionDays();

        // Server-generated gap for the silence BEFORE this batch. Guarded in SQL
        // so two concurrent batches cannot both insert one.
        const gap = await db.query(
          `INSERT INTO interview_presence_events
             (session_id, event_type, started_at, ended_at, duration_ms,
              detector_version, thresholds, source, purge_after)
           SELECT s.id, 'monitoring_gap', s.last_report_at, NOW(),
                  GREATEST(0, FLOOR(EXTRACT(EPOCH FROM (NOW() - s.last_report_at)) * 1000))::int,
                  s.detector_version, s.thresholds, 'server',
                  NOW() + ($2::int * INTERVAL '1 day')
           FROM interview_presence_sessions s
           WHERE s.id = $1
             AND s.last_report_at IS NOT NULL
             AND s.last_report_at < NOW() - ($3::int * INTERVAL '1 second')`,
          [session.id, retention, config.gapSeconds()]
        );

        // The batch. detector_version and thresholds come from the SESSION row —
        // the operating point of a record is never what the client says it was.
        let accepted = 0;
        if (verdict.events.length > 0) {
          const values = [];
          const params = [session.id, session.detector_version, JSON.stringify(session.thresholds), retention];
          let p = params.length;
          for (const ev of verdict.events) {
            values.push(
              `($1, $${p + 1}, $${p + 2}::timestamptz, $${p + 3}::timestamptz, $${p + 4}::int, ` +
              `$2, $3::jsonb, 'client', NOW() + ($4::int * INTERVAL '1 day'))`
            );
            params.push(ev.eventType, ev.startedAt, ev.endedAt, ev.durationMs);
            p += 4;
          }
          const ins = await db.query(
            `INSERT INTO interview_presence_events
               (session_id, event_type, started_at, ended_at, duration_ms,
                detector_version, thresholds, source, purge_after)
             VALUES ${values.join(', ')}`,
            params
          );
          accepted = (ins && typeof ins.rowCount === 'number') ? ins.rowCount : verdict.events.length;
        }

        await db.query(
          `UPDATE interview_presence_sessions
           SET last_report_at = NOW(), ended_at = NULL
           WHERE id = $1`,
          [session.id]
        );

        // Counts only — never the payload.
        logger.log(`[presence] ingest code=${code} accepted=${accepted}`);
        return res.json({
          accepted,
          gapRecorded: !!(gap && gap.rowCount > 0),
        });
      } catch (err) {
        return unavailable(res, 'event ingest', err);
      }
    }
  );

  // -------------------------------------------------------------------------
  // Timeline assembly — shared by the timeline read and the export
  // -------------------------------------------------------------------------

  function msBetween(a, b) {
    return Math.max(0, Math.round(new Date(b).getTime() - new Date(a).getTime()));
  }

  /// Build the reviewer-facing payload for one session.
  ///
  /// EVALUATION SURFACE: per-type counts and durations ONLY. No total, no
  /// weighting, no normalisation, no percentage, no rating, no risk level, no
  /// colour-coded level, and no comparison to any other candidate or session —
  /// now or ever. Seven reasons are recorded in research memo section 7.2; the
  /// short version is that an aggregate invites an automated decision the law
  /// forbids and the evidence does not support. Per-type counts keep the
  /// interviewer looking at the thing that happened, under the operating point
  /// it was recorded at.
  async function buildTimeline(session, roomData) {
    const sessionId = session.id;

    const summaryRes = await db.query(
      `SELECT event_type, COUNT(*)::int AS count,
              COALESCE(SUM(duration_ms), 0)::bigint AS total_duration_ms
       FROM interview_presence_events
       WHERE session_id = $1
       GROUP BY event_type
       ORDER BY event_type`,
      [sessionId]
    );

    const eventsRes = await db.query(
      `SELECT id, event_type, started_at, ended_at, duration_ms,
              detector_version, thresholds, source
       FROM interview_presence_events
       WHERE session_id = $1
       ORDER BY started_at ASC, id ASC
       LIMIT ${MAX_TIMELINE_EVENTS}`,
      [sessionId]
    );

    const notesRes = await db.query(
      `SELECT n.id, n.event_id, n.author_display_name, n.note_text_enc, n.created_at
       FROM interview_presence_notes n
       JOIN interview_presence_events e ON e.id = n.event_id
       WHERE e.session_id = $1
       ORDER BY n.created_at ASC`,
      [sessionId]
    );

    const notesByEvent = new Map();
    for (const n of notesRes.rows) {
      const text = crypto.decryptToken(n.note_text_enc);
      if (text === null) {
        // Never log the blob. A key that cannot decrypt is an operator problem,
        // not a reason to drop the note's existence from the record.
        logger.error(`[presence] note ${n.id} could not be decrypted with the configured keys`);
      }
      const list = notesByEvent.get(String(n.event_id)) || [];
      list.push({
        author: n.author_display_name,
        createdAt: new Date(n.created_at).toISOString(),
        text,
      });
      notesByEvent.set(String(n.event_id), list);
    }

    const startedAtISO = new Date(session.started_at).toISOString();
    const endedAtISO = session.ended_at ? new Date(session.ended_at).toISOString() : null;
    const nowISO = new Date().toISOString();

    const events = eventsRes.rows.map((e) => ({
      id: Number(e.id),
      eventType: e.event_type,
      startedAt: new Date(e.started_at).toISOString(),
      endedAt: e.ended_at ? new Date(e.ended_at).toISOString() : null,
      durationMs: Number(e.duration_ms),
      offsetMs: msBetween(startedAtISO, e.started_at),
      detectorVersion: e.detector_version,
      thresholds: e.thresholds,
      source: e.source,
      liveSurfaceable: LIVE_SURFACEABLE.includes(e.event_type),
      notes: notesByEvent.get(String(e.id)) || [],
    }));

    const summary = summaryRes.rows.map((r) => ({
      eventType: r.event_type,
      count: Number(r.count),
      totalDurationMs: Number(r.total_duration_ms),
      liveSurfaceable: LIVE_SURFACEABLE.includes(r.event_type),
    }));

    // An OPEN gap: the session is live and has gone quiet. Computed on the fly
    // and NOT persisted, because it is still running — the sweeper closes it.
    if (session.monitoring_enabled === true && !session.ended_at && session.last_report_at) {
      const silentMs = msBetween(session.last_report_at, nowISO);
      if (silentMs > config.gapSeconds() * 1000) {
        const openGap = {
          id: null,
          eventType: 'monitoring_gap',
          startedAt: new Date(session.last_report_at).toISOString(),
          endedAt: null,
          durationMs: silentMs,
          offsetMs: msBetween(startedAtISO, session.last_report_at),
          detectorVersion: session.detector_version,
          thresholds: session.thresholds,
          source: 'server',
          liveSurfaceable: false,
          notes: [],
        };
        events.push(openGap);
        const existing = summary.find((s) => s.eventType === 'monitoring_gap');
        if (existing) {
          existing.count += 1;
          existing.totalDurationMs += silentMs;
        } else {
          summary.push({
            eventType: 'monitoring_gap',
            count: 1,
            totalDurationMs: silentMs,
            liveSurfaceable: false,
          });
        }
      }
    }

    return {
      monitoringEnabled: session.monitoring_enabled === true,
      consentState: session.consent_state,
      consentVersion: session.consent_version,
      policyRegionEU: session.policy_region_eu === true,
      policyUnder18: session.policy_under_18 === true,
      detectorVersion: session.detector_version || detectorVersionFor(roomData),
      thresholds: session.thresholds,
      multipleFacesEnabled: session.multiple_faces_enabled === true,
      sessionStartedAt: startedAtISO,
      sessionEndedAt: endedAtISO,
      sessionDurationMs: msBetween(startedAtISO, endedAtISO || nowISO),
      summary,
      events,
    };
  }

  // =========================================================================
  // GET /presence/timeline/:code/:identity?callerIdentity=...
  // Auth: Bearer token + moderator role in the room
  // =========================================================================
  router.get('/timeline/:code/:identity',
    requireAuth,
    makePresenceRateLimiter('presence-timeline', 60, 60),
    requireModerator,
    async (req, res) => {
      const code = req.presenceCode;
      const identity = req.presenceIdentity;
      try {
        const session = await loadSession(code, identity);
        if (!session) {
          return res.status(404).json({
            error: 'No presence session for this participant.',
            code: 'PRESENCE_SESSION_NOT_FOUND',
          });
        }
        const payload = await buildTimeline(session, req.presenceRoom);
        auditLog(req.user.userId, 'presence_timeline_read', req.ip, {
          roomCode: code, identity, eventCount: payload.events.length,
        });
        return res.json(payload);
      } catch (err) {
        return unavailable(res, 'timeline read', err);
      }
    }
  );

  // =========================================================================
  // POST /presence/timeline/:code/:identity/note
  // Body: { callerIdentity, eventId, note }
  // Auth: Bearer token + moderator role in the room
  //
  // Additive and never destructive: a note annotates one event and changes
  // nothing about it. The >= 10 character rule is the same mandatory-reason
  // discipline used for a human override elsewhere — a judgement about a named
  // person has to be written down to be reviewable.
  // =========================================================================
  router.post('/timeline/:code/:identity/note',
    requireAuth,
    makePresenceRateLimiter('presence-note', 30, 600),
    requireModerator,
    async (req, res) => {
      const code = req.presenceCode;
      const identity = req.presenceIdentity;
      const rawNote = (req.body && req.body.note);
      const note = typeof rawNote === 'string' ? rawNote.trim() : '';
      const eventId = req.body && req.body.eventId;

      if (!Number.isInteger(eventId) || eventId <= 0) {
        return res.status(400).json({
          error: 'eventId must be a positive integer.',
          code: 'PRESENCE_PAYLOAD_INVALID',
          field: 'eventId',
        });
      }
      if (note.length < MIN_NOTE_LENGTH) {
        return res.status(400).json({
          error: `A note must be at least ${MIN_NOTE_LENGTH} characters so the reasoning is on the record.`,
          code: 'PRESENCE_NOTE_REASON_REQUIRED',
          field: 'note',
        });
      }
      if (note.length > MAX_NOTE_LENGTH) {
        return res.status(400).json({
          error: `A note may be at most ${MAX_NOTE_LENGTH} characters.`,
          code: 'PRESENCE_PAYLOAD_INVALID',
          field: 'note',
        });
      }

      // Fail closed rather than storing a human judgement about a named person
      // in plaintext (the calendar.js precedent).
      if (!crypto.isEncryptionAvailable()) {
        logger.error('[presence] note rejected: no encryption key configured');
        return res.status(500).json({
          error: 'Notes are unavailable because encryption is not configured.',
          code: 'ENCRYPTION_UNAVAILABLE',
        });
      }

      try {
        const session = await loadSession(code, identity);
        if (!session) {
          return res.status(404).json({
            error: 'No presence session for this participant.',
            code: 'PRESENCE_SESSION_NOT_FOUND',
          });
        }
        const owned = await db.query(
          'SELECT id FROM interview_presence_events WHERE id = $1 AND session_id = $2',
          [eventId, session.id]
        );
        if (owned.rows.length === 0) {
          return res.status(404).json({
            error: 'That event is not part of this session.',
            code: 'PRESENCE_SESSION_NOT_FOUND',
          });
        }

        const enc = crypto.encryptToken(note);
        if (!enc) {
          logger.error('[presence] note rejected: encryption returned no ciphertext');
          return res.status(500).json({
            error: 'Notes are unavailable because encryption is not configured.',
            code: 'ENCRYPTION_UNAVAILABLE',
          });
        }

        let authorName = 'Interviewer';
        try {
          const u = await db.query('SELECT display_name FROM users WHERE id = $1', [req.user.userId]);
          if (u.rows[0] && u.rows[0].display_name) authorName = String(u.rows[0].display_name).slice(0, 100);
        } catch (err) {
          logger.error(`[presence] author name lookup failed: ${err.message}`);
        }

        const ins = await db.query(
          `INSERT INTO interview_presence_notes
             (event_id, author_user_id, author_display_name, note_text_enc, note_key_version)
           VALUES ($1, $2, $3, $4, $5)
           RETURNING id, created_at`,
          [eventId, req.user.userId, authorName, enc, crypto.getActiveVersion()]
        );

        // Length only — the note text itself never reaches the audit trail.
        auditLog(req.user.userId, 'presence_note_added', req.ip, {
          roomCode: code, identity, eventId, noteLength: note.length,
        });

        return res.status(201).json({
          noteId: ins.rows[0].id,
          createdAt: new Date(ins.rows[0].created_at).toISOString(),
          author: authorName,
        });
      } catch (err) {
        return unavailable(res, 'note write', err);
      }
    }
  );

  // =========================================================================
  // GET /presence/export/:code/:identity?format=json|csv&callerIdentity=...
  // Auth: Bearer token + moderator role in the room
  // =========================================================================

  const CSV_HEADER = 'event_type,started_at,ended_at,duration_ms,offset_ms,detector_version,source,thresholds_json';

  /// Quote a CSV field and defuse spreadsheet formula injection: a value that
  /// begins =, +, - or @ is prefixed with an apostrophe so Excel / Numbers /
  /// Sheets treat it as text (OWASP CSV-injection guidance).
  function csvField(value) {
    let s = value === null || value === undefined ? '' : String(value);
    if (/^[=+\-@]/.test(s)) s = `'${s}`;
    return `"${s.replace(/"/g, '""')}"`;
  }

  function timelineToCSV(payload) {
    const lines = [CSV_HEADER];
    for (const e of payload.events) {
      lines.push([
        csvField(e.eventType),
        csvField(e.startedAt),
        csvField(e.endedAt),
        csvField(e.durationMs),
        csvField(e.offsetMs),
        csvField(e.detectorVersion),
        csvField(e.source),
        csvField(JSON.stringify(e.thresholds)),
      ].join(','));
    }
    return lines.join('\r\n') + '\r\n';
  }

  router.get('/export/:code/:identity',
    requireAuth,
    makePresenceRateLimiter('presence-export', 10, 600),
    requireModerator,
    async (req, res) => {
      const code = req.presenceCode;
      const identity = req.presenceIdentity;
      const format = (req.query && req.query.format === 'csv') ? 'csv' : 'json';
      try {
        const session = await loadSession(code, identity);
        if (!session) {
          return res.status(404).json({
            error: 'No presence session for this participant.',
            code: 'PRESENCE_SESSION_NOT_FOUND',
          });
        }
        const payload = await buildTimeline(session, req.presenceRoom);
        auditLog(req.user.userId, 'presence_export', req.ip, {
          roomCode: code, identity, format, eventCount: payload.events.length,
        });

        if (format === 'csv') {
          // sanitizeFilename before the value reaches a response header.
          const safe = `presence-${sanitizeFilename(code)}-${sanitizeFilename(identity)}.csv`;
          res.setHeader('Content-Type', 'text/csv; charset=utf-8');
          res.setHeader('Content-Disposition', `attachment; filename="${safe}"`);
          return res.send(timelineToCSV(payload));
        }
        return res.json(payload);
      } catch (err) {
        return unavailable(res, 'export', err);
      }
    }
  );

  return router;
}

module.exports = { createPresenceRouter, LIVE_SURFACEABLE };
