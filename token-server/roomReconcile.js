// ============================================================================
// roomReconcile.js
//
// Reconciles the Redis participant set against LiveKit's authoritative room
// occupancy. The Redis set is a denormalized cache that can strand a ghost
// identity (e.g. a stale host identity that was previously only reaped on
// rejoin), leaving `remaining >= 1` for a room that is actually empty — so the
// `remaining === 0` cleanup never fires.
//
// The reconciler only ACTS when LiveKit confirms the room has ZERO connected
// participants, in which case every residual Redis entry is provably a ghost
// and is safe to purge. It NEVER deletes the room hash itself, so a room the
// host left (without ending it for all) stays active and rejoinable.
//
// Extracted as a dependency-injected factory so it can be unit-tested without
// standing up the full token server (which connects to Redis + LiveKit on
// require). index.js wires in the real `redis`, `roomService`, and key helpers.
// ============================================================================

/// Build a `reconcileEmptyRoom(code, roomName, redisRemaining)` function.
///
/// Dependencies:
///   - redis:       ioredis-like client exposing `del(key)`.
///   - roomService: LiveKit RoomServiceClient exposing `listRooms([roomName])`
///                  whose entries carry a numeric `numParticipants`.
///   - keys:        { participantsKey, rolesKey, namesKey } — code → redis key.
///   - logger:      console-like (defaults to console).
function createReconcileEmptyRoom({ redis, roomService, keys, logger = console }) {
  const { participantsKey, rolesKey, namesKey } = keys;

  /// Returns the EFFECTIVE remaining participant count:
  ///   - `redisRemaining` unchanged when it is already <= 0, when no roomName is
  ///     given, or when the LiveKit query throws (fail-safe — identical to the
  ///     pre-reconcile behavior).
  ///   - `0` when LiveKit reports the room empty (stale membership is purged).
  return async function reconcileEmptyRoom(code, roomName, redisRemaining) {
    if (redisRemaining <= 0 || !roomName) return redisRemaining;
    try {
      const rooms = await roomService.listRooms([roomName]);
      const liveCount = (rooms && rooms[0] && typeof rooms[0].numParticipants === 'number')
        ? rooms[0].numParticipants
        : 0;
      if (liveCount === 0) {
        // Room is empty in LiveKit but Redis still lists members → purge ghosts.
        // Membership hashes only (participants/roles/names); the room hash is
        // left intact so the host can rejoin an un-ended room.
        await redis.del(participantsKey(code));
        await redis.del(rolesKey(code));
        await redis.del(namesKey(code));
        logger.log(`[reconcile] code=${code} room empty in LiveKit but Redis had ${redisRemaining} member(s) — purged stale membership`);
        return 0;
      }
    } catch (err) {
      logger.error(`[reconcile] LiveKit occupancy check failed for code=${code}: ${err.message}`);
    }
    return redisRemaining;
  };
}

module.exports = { createReconcileEmptyRoom };
