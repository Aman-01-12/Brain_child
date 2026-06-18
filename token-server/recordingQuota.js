// ============================================================================
// recordingQuota.js
//
// Server-side enforcement that a single cloud recording cannot overrun the
// recording account's quota (and the operator's egress/storage cost). The quota
// is checked at /room/record/start against a CLIENT-SUPPLIED estimate, so a client
// that under-reports duration could otherwise record indefinitely. At start we
// persist max_duration_seconds (= remaining quota at that moment); this sweeper
// periodically stops any active egress whose elapsed time has exceeded its cap. (F1)
//
// Dependency-injected (like roomReconcile.js / joinGuards.js) so the decision +
// stop orchestration unit-test without a live DB/LiveKit/Redis.
// ============================================================================

/// Pure predicate: has an active recording exceeded its hard cap?
/// A null/absent cap means "no cap recorded" → never force-stopped here.
function isRecordingOverCap(elapsedSeconds, maxDurationSeconds) {
  if (maxDurationSeconds == null) return false;
  const cap = Number(maxDurationSeconds);
  const elapsed = Number(elapsedSeconds);
  if (!Number.isFinite(cap) || cap <= 0) return false;
  if (!Number.isFinite(elapsed)) return false;
  return elapsed >= cap;
}

/// Build a sweeper that stops over-cap recordings in one pass.
///
/// Dependencies:
///   - db:          pg-like client exposing query(text, params).
///   - egressClient: LiveKit EgressClient exposing stopEgress(egressId).
///   - redis:       ioredis-like (used to clear the room's recording metadata flag).
///   - roomKey:     code -> redis room hash key.
///   - logger:      console-like.
function createOverdueRecordingSweeper({ db, egressClient, redis, roomKey, logger = console }) {

  async function stopOneSession(session) {
    const egressId = session.egress_id;
    // Stop multi-track participant egresses if present; else the single composite egress.
    const tracks = await db.query(
      `SELECT egress_id FROM recording_tracks
       WHERE session_id = $1 AND status = 'active'`,
      [session.id]
    );
    if (tracks.rows.length > 0) {
      for (const t of tracks.rows) {
        try { await egressClient.stopEgress(t.egress_id); }
        catch (e) { logger.error(`[quota-sweeper] stop track egress ${t.egress_id} failed: ${e.message}`); }
      }
      await db.query(
        `UPDATE recording_tracks SET status = 'finalizing'
         WHERE session_id = $1 AND status = 'active'`,
        [session.id]
      );
    } else {
      await egressClient.stopEgress(egressId);
    }
    // Mark finalizing — the egress webhook completes the rest (duration, quota debit).
    await db.query(
      `UPDATE recording_sessions SET status = 'finalizing' WHERE id = $1`,
      [session.id]
    );
    // Best-effort: clear the room's recording metadata flag so clients stop showing REC.
    if (session.room_code) {
      try {
        const existing = await redis.hget(roomKey(session.room_code), 'metadata');
        const meta = existing ? JSON.parse(existing) : {};
        meta.recording = false;
        delete meta.recordingMode;
        delete meta.recordingSessionId;
        await redis.hset(roomKey(session.room_code), 'metadata', JSON.stringify(meta));
      } catch (e) {
        logger.error(`[quota-sweeper] clear metadata for ${session.room_code} failed: ${e.message}`);
      }
    }
  }

  /// Run one sweep. Returns the number of sessions stopped.
  return async function sweepOnce() {
    const { rows } = await db.query(
      `SELECT id, egress_id, room_name, room_code, max_duration_seconds,
              EXTRACT(EPOCH FROM (NOW() - started_at)) AS elapsed_seconds
       FROM recording_sessions
       WHERE status = 'active'
         AND egress_id IS NOT NULL
         AND max_duration_seconds IS NOT NULL`
    );
    let stopped = 0;
    for (const s of rows) {
      if (!isRecordingOverCap(s.elapsed_seconds, s.max_duration_seconds)) continue;
      logger.log(`[quota-sweeper] stopping over-cap recording id=${s.id} egress=${s.egress_id} ` +
        `elapsed=${Math.round(Number(s.elapsed_seconds))}s cap=${s.max_duration_seconds}s`);
      try {
        await stopOneSession(s);
        stopped++;
      } catch (e) {
        logger.error(`[quota-sweeper] failed to stop session ${s.id}: ${e.message}`);
      }
    }
    return stopped;
  };
}

module.exports = { isRecordingOverCap, createOverdueRecordingSweeper };
