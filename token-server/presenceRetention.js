// ============================================================================
// presenceRetention.js — PRESENCE MONITORING (provisional)
//
// The automated retention sweeper. Two obligations, discharged on a timer rather
// than on an operator remembering:
//
//   1. PURGE: delete session and event rows whose per-row purge_after clock has
//      come due. The clock is stamped at insert from PRESENCE_EVENT_RETENTION_DAYS,
//      so changing that env var produces new clocks on NEW rows and never
//      rewrites existing ones.
//   2. CLOSE STALE SESSIONS: a session that stopped reporting and was never
//      closed gets one terminal monitoring_gap spanning the silence, then
//      ended_at. Silence is recorded as silence — not as a clean session, and
//      not as anything about the candidate.
//
// Idempotent by construction: every statement is guarded by a predicate that the
// first run falsifies (purge_after <= NOW(), ended_at IS NULL).
//
// Dependency-injected exactly like recordingQuota.js so it unit-tests with fakes
// and never needs a live DB.
// ============================================================================

/// Build the presence retention sweeper.
///
/// Dependencies:
///   - db:       pg-like client exposing query(text, params).
///   - auditLog: auth.auditLog(userId, eventType, ipAddress, metadata). Never
///               awaited (house convention) and never passed anything sensitive.
///   - config:   presenceConfig (retentionDays, staleSessionMinutes).
///   - logger:   console-like.
///
/// Returns sweepOnce() -> { eventRows, sessionRows, staleClosed }.
function createPresenceSweeper({ db, auditLog, config, logger = console }) {

  /// Delete due event rows. Guarded by purge_after <= NOW(), so a row whose
  /// clock is in the future is untouched and a second run deletes nothing.
  async function purgeDueEvents() {
    const res = await db.query(
      `DELETE FROM interview_presence_events
       WHERE purge_after <= NOW()`
    );
    return res && typeof res.rowCount === 'number' ? res.rowCount : 0;
  }

  /// Delete due session rows. Their events and notes cascade (migration 023),
  /// which is also what makes a candidate erasure a single DELETE.
  async function purgeDueSessions() {
    const res = await db.query(
      `DELETE FROM interview_presence_sessions
       WHERE purge_after <= NOW()`
    );
    return res && typeof res.rowCount === 'number' ? res.rowCount : 0;
  }

  /// Close sessions that are still live but stopped reporting: one terminal
  /// monitoring_gap spanning [last_report_at, NOW()], then ended_at = NOW().
  /// The ended_at IS NULL guard makes a second run a no-op.
  async function closeStaleSessions() {
    const staleMinutes = config.staleSessionMinutes();
    const { rows } = await db.query(
      `SELECT id, last_report_at, detector_version, thresholds
       FROM interview_presence_sessions
       WHERE monitoring_enabled = TRUE
         AND ended_at IS NULL
         AND last_report_at IS NOT NULL
         AND last_report_at < NOW() - ($1::int * INTERVAL '1 minute')`,
      [staleMinutes]
    );

    let closed = 0;
    for (const row of rows) {
      try {
        // source = 'server': a client can neither forge nor suppress a gap.
        // detector_version and thresholds are copied from the SESSION row, never
        // from anything a client sent.
        await db.query(
          `INSERT INTO interview_presence_events
             (session_id, event_type, started_at, ended_at, duration_ms,
              detector_version, thresholds, source, purge_after)
           SELECT s.id, 'monitoring_gap', s.last_report_at, NOW(),
                  GREATEST(0, FLOOR(EXTRACT(EPOCH FROM (NOW() - s.last_report_at)) * 1000))::int,
                  s.detector_version, s.thresholds, 'server',
                  NOW() + ($2::int * INTERVAL '1 day')
           FROM interview_presence_sessions s
           WHERE s.id = $1 AND s.ended_at IS NULL AND s.last_report_at IS NOT NULL`,
          [row.id, config.retentionDays()]
        );
        const upd = await db.query(
          `UPDATE interview_presence_sessions
           SET ended_at = NOW()
           WHERE id = $1 AND ended_at IS NULL`,
          [row.id]
        );
        const updated = (upd && typeof upd.rowCount === 'number') ? upd.rowCount : 1;
        if (updated > 0) closed++;
      } catch (err) {
        logger.error(`[presence-sweeper] closing stale session ${row.id} failed: ${err.message}`);
      }
    }
    return closed;
  }

  /// Run one sweep. Never throws: a DB blip must not take down the timer that
  /// discharges the retention obligation, and the next tick retries.
  return async function sweepOnce() {
    let eventRows = 0;
    let sessionRows = 0;
    let staleClosed = 0;

    try {
      eventRows = await purgeDueEvents();
    } catch (err) {
      logger.error(`[presence-sweeper] event purge failed: ${err.message}`);
    }
    try {
      sessionRows = await purgeDueSessions();
    } catch (err) {
      logger.error(`[presence-sweeper] session purge failed: ${err.message}`);
    }
    try {
      staleClosed = await closeStaleSessions();
    } catch (err) {
      logger.error(`[presence-sweeper] stale-session close failed: ${err.message}`);
    }

    if (eventRows > 0 || sessionRows > 0) {
      logger.log(`[presence-sweeper] purged events=${eventRows} sessions=${sessionRows} staleClosed=${staleClosed}`);
      // Only audited when something was actually deleted — an audit row per
      // idle tick would bury the ones that mean something. userId is null: the
      // sweeper acts on nobody's behalf.
      if (typeof auditLog === 'function') {
        auditLog(null, 'presence_events_purged', null, {
          eventRows,
          sessionRows,
          retentionDays: config.retentionDays(),
        });
      }
    }

    return { eventRows, sessionRows, staleClosed };
  };
}

module.exports = { createPresenceSweeper };
