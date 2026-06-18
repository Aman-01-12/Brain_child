// ============================================================================
// joinGuards.js
//
// Admission guards for the OPEN /room/join endpoint. Because join requires no
// auth (guests are a product feature) and is rate-limited only by a client-
// rotatable `identity`, an attacker holding a room code can otherwise:
//   1. Exhaust the participant cap with HTTP-only joins that never connect to
//      LiveKit (the Redis participant set is sadd-ed before any WebRTC connect),
//      locking out real users with a bogus "Room full".
//   2. Flood the waiting-room sorted set unboundedly.
//
// These guards are dependency-injected (like roomReconcile.js) so they unit-test
// without standing up Redis or LiveKit.
// ============================================================================

/// Build an authoritative participant-cap check.
///
/// The Redis participant set is a denormalized cache that an HTTP-only join can
/// inflate without ever connecting. LiveKit's `numParticipants` is the
/// authoritative, unspoofable occupancy — to count there you must complete a
/// real WebRTC connection. So when Redis claims the room is full we cross-check
/// LiveKit before rejecting: if LiveKit shows headroom, the Redis count is
/// inflated by ghosts/never-connected joins and the join is allowed.
///
/// Dependencies:
///   - roomService:     LiveKit RoomServiceClient exposing `listRooms([roomName])`.
///   - maxParticipants: hard cap.
///   - logger:          console-like (defaults to console).
function createJoinCapGuard({ roomService, maxParticipants, logger = console }) {
  /// Decide whether a join may proceed under the participant cap.
  ///   - alreadyIn (reconnect) always passes — never lock out an existing peer.
  ///   - Below the cap in Redis → pass without a LiveKit round-trip (hot path
  ///     unaffected; only the contested at-cap path pays the extra call).
  ///   - At/over the cap → authoritative LiveKit occupancy decides.
  ///   - LiveKit error → fail SAFE to the prior behaviour (reject at cap), so a
  ///     transient LiveKit blip cannot be used to blow past the cap.
  ///
  /// Returns { allowed: boolean, liveCount: number|null }.
  return async function isJoinWithinCap({ roomName, redisCount, alreadyIn }) {
    if (alreadyIn) return { allowed: true, liveCount: null };
    if (typeof redisCount === 'number' && redisCount < maxParticipants) {
      return { allowed: true, liveCount: null };
    }
    if (!roomName) return { allowed: false, liveCount: null };
    try {
      const rooms = await roomService.listRooms([roomName]);
      const liveCount = (rooms && rooms[0] && typeof rooms[0].numParticipants === 'number')
        ? rooms[0].numParticipants
        : 0;
      return { allowed: liveCount < maxParticipants, liveCount };
    } catch (err) {
      logger.error(`[joinCap] LiveKit occupancy check failed for room=${roomName}: ${err.message}`);
      return { allowed: false, liveCount: null }; // fail safe (reject at cap)
    }
  };
}

module.exports = { createJoinCapGuard };
