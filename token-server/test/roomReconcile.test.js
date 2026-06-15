// ============================================================================
// roomReconcile — unit tests (node:test)
//
// Exercises createReconcileEmptyRoom in isolation with a fake LiveKit
// roomService and a fake redis. No DB/Redis/LiveKit needed — the reconciler is
// dependency-injected, so these are fast, deterministic, and CI-safe.
//
// Covered:
//   - already-empty (remaining<=0) → no-op, no LiveKit call, no deletes
//   - missing roomName → no-op
//   - LiveKit reports 0 participants → purge membership, returns 0
//   - LiveKit reports >0 participants → no purge, returns original count
//   - LiveKit room not found (empty list) → treated as empty → purge
//   - LiveKit throws → fail-safe, returns original count, no deletes
// ============================================================================

const { test } = require('node:test');
const assert = require('node:assert');
const { createReconcileEmptyRoom } = require('../roomReconcile');

const KEYS = {
  participantsKey: (c) => `room:${c}:participants`,
  rolesKey: (c) => `room:${c}:roles`,
  namesKey: (c) => `room:${c}:names`,
};

// Silent logger so test output stays clean.
const silentLogger = { log() {}, error() {} };

function makeRedis() {
  const deleted = [];
  return {
    deleted,
    async del(key) { deleted.push(key); return 1; },
  };
}

// roomService stub: `mode` controls listRooms behavior.
function makeRoomService(mode) {
  const calls = [];
  return {
    calls,
    async listRooms(names) {
      calls.push(names);
      switch (mode.kind) {
        case 'empty':      return [{ name: names[0], numParticipants: 0 }];
        case 'occupied':   return [{ name: names[0], numParticipants: mode.count }];
        case 'notFound':   return [];
        case 'throws':     throw new Error('LiveKit unreachable');
        default:           return [];
      }
    },
  };
}

test('reconcileEmptyRoom', async (t) => {

  await t.test('no-op when remaining is already 0 (no LiveKit call, no deletes)', async () => {
    const redis = makeRedis();
    const roomService = makeRoomService({ kind: 'empty' });
    const reconcile = createReconcileEmptyRoom({ redis, roomService, keys: KEYS, logger: silentLogger });

    const result = await reconcile('ABC123', 'inter-ABC123', 0);

    assert.equal(result, 0);
    assert.equal(roomService.calls.length, 0, 'LiveKit not queried');
    assert.equal(redis.deleted.length, 0, 'nothing deleted');
  });

  await t.test('no-op when roomName is missing', async () => {
    const redis = makeRedis();
    const roomService = makeRoomService({ kind: 'empty' });
    const reconcile = createReconcileEmptyRoom({ redis, roomService, keys: KEYS, logger: silentLogger });

    const result = await reconcile('ABC123', '', 3);

    assert.equal(result, 3, 'original count returned unchanged');
    assert.equal(roomService.calls.length, 0, 'LiveKit not queried');
    assert.equal(redis.deleted.length, 0);
  });

  await t.test('purges stale membership and returns 0 when LiveKit room is empty', async () => {
    const redis = makeRedis();
    const roomService = makeRoomService({ kind: 'empty' });
    const reconcile = createReconcileEmptyRoom({ redis, roomService, keys: KEYS, logger: silentLogger });

    const result = await reconcile('ABC123', 'inter-ABC123', 1);

    assert.equal(result, 0, 'effective remaining is 0 → triggers cleanup');
    assert.deepEqual(roomService.calls, [['inter-ABC123']], 'queried LiveKit by room name');
    assert.deepEqual(
      redis.deleted.sort(),
      ['room:ABC123:names', 'room:ABC123:participants', 'room:ABC123:roles'].sort(),
      'participants + roles + names purged'
    );
  });

  await t.test('does NOT purge when LiveKit still has participants', async () => {
    const redis = makeRedis();
    const roomService = makeRoomService({ kind: 'occupied', count: 2 });
    const reconcile = createReconcileEmptyRoom({ redis, roomService, keys: KEYS, logger: silentLogger });

    const result = await reconcile('ABC123', 'inter-ABC123', 3);

    assert.equal(result, 3, 'original Redis count returned (room not empty)');
    assert.equal(redis.deleted.length, 0, 'no membership purged while live participants remain');
  });

  await t.test('treats a LiveKit-unknown room (empty list) as empty → purge', async () => {
    const redis = makeRedis();
    const roomService = makeRoomService({ kind: 'notFound' });
    const reconcile = createReconcileEmptyRoom({ redis, roomService, keys: KEYS, logger: silentLogger });

    const result = await reconcile('ZZZ999', 'inter-ZZZ999', 1);

    assert.equal(result, 0, 'no LiveKit room means nobody is connected');
    assert.equal(redis.deleted.length, 3, 'stale membership purged');
  });

  await t.test('fails safe (returns original count, no deletes) when LiveKit throws', async () => {
    const redis = makeRedis();
    const roomService = makeRoomService({ kind: 'throws' });
    const reconcile = createReconcileEmptyRoom({ redis, roomService, keys: KEYS, logger: silentLogger });

    const result = await reconcile('ABC123', 'inter-ABC123', 2);

    assert.equal(result, 2, 'pre-reconcile behavior preserved on LiveKit error');
    assert.equal(redis.deleted.length, 0, 'no deletes on error — never strands a live room');
  });
});
