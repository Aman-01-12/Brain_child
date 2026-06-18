// ============================================================================
// joinGuards — unit tests (node:test)
//
// Exercises createJoinCapGuard in isolation with a fake LiveKit roomService.
// No Redis/LiveKit needed — the guard is dependency-injected.
//
// Covered:
//   - reconnect (alreadyIn) → allowed, no LiveKit call
//   - below cap → allowed, no LiveKit call (hot path: no round-trip)
//   - at cap, LiveKit has headroom → allowed (Redis ghosts ignored)
//   - at cap, LiveKit also full → rejected
//   - at cap, LiveKit room not found (empty list) → treated as 0 → allowed
//   - at cap, LiveKit throws → fail SAFE (rejected), no blow-past
//   - at cap, missing roomName → rejected
// ============================================================================

const { test } = require('node:test');
const assert = require('node:assert');
const { createJoinCapGuard } = require('../joinGuards');

const silentLogger = { log() {}, error() {} };
const MAX = 50;

function makeRoomService(mode, count = 0) {
  const calls = [];
  return {
    calls,
    async listRooms(names) {
      calls.push(names);
      if (mode === 'throw') throw new Error('LiveKit unreachable');
      if (mode === 'empty') return [];
      return [{ numParticipants: count }];
    },
  };
}

test('reconnect is always allowed without a LiveKit call', async () => {
  const svc = makeRoomService('ok', 50);
  const guard = createJoinCapGuard({ roomService: svc, maxParticipants: MAX, logger: silentLogger });
  const r = await guard({ roomName: 'inter-ABC', redisCount: 999, alreadyIn: true });
  assert.deepStrictEqual(r, { allowed: true, liveCount: null });
  assert.strictEqual(svc.calls.length, 0, 'must not query LiveKit for a reconnect');
});

test('below cap is allowed without a LiveKit call (hot path)', async () => {
  const svc = makeRoomService('ok', 0);
  const guard = createJoinCapGuard({ roomService: svc, maxParticipants: MAX, logger: silentLogger });
  const r = await guard({ roomName: 'inter-ABC', redisCount: 49, alreadyIn: false });
  assert.deepStrictEqual(r, { allowed: true, liveCount: null });
  assert.strictEqual(svc.calls.length, 0, 'no round-trip below the cap');
});

test('at cap but LiveKit has headroom → allowed (ghost joins ignored)', async () => {
  const svc = makeRoomService('ok', 5);
  const guard = createJoinCapGuard({ roomService: svc, maxParticipants: MAX, logger: silentLogger });
  const r = await guard({ roomName: 'inter-ABC', redisCount: 80, alreadyIn: false });
  assert.strictEqual(r.allowed, true);
  assert.strictEqual(r.liveCount, 5);
  assert.strictEqual(svc.calls.length, 1);
});

test('at cap and LiveKit also full → rejected', async () => {
  const svc = makeRoomService('ok', 50);
  const guard = createJoinCapGuard({ roomService: svc, maxParticipants: MAX, logger: silentLogger });
  const r = await guard({ roomName: 'inter-ABC', redisCount: 50, alreadyIn: false });
  assert.strictEqual(r.allowed, false);
  assert.strictEqual(r.liveCount, 50);
});

test('at cap and LiveKit room not found → treated as empty → allowed', async () => {
  const svc = makeRoomService('empty');
  const guard = createJoinCapGuard({ roomService: svc, maxParticipants: MAX, logger: silentLogger });
  const r = await guard({ roomName: 'inter-ABC', redisCount: 50, alreadyIn: false });
  assert.strictEqual(r.allowed, true);
  assert.strictEqual(r.liveCount, 0);
});

test('at cap and LiveKit throws → fail safe (rejected), no blow-past', async () => {
  const svc = makeRoomService('throw');
  const guard = createJoinCapGuard({ roomService: svc, maxParticipants: MAX, logger: silentLogger });
  const r = await guard({ roomName: 'inter-ABC', redisCount: 50, alreadyIn: false });
  assert.deepStrictEqual(r, { allowed: false, liveCount: null });
});

test('at cap with missing roomName → rejected (cannot verify occupancy)', async () => {
  const svc = makeRoomService('ok', 0);
  const guard = createJoinCapGuard({ roomService: svc, maxParticipants: MAX, logger: silentLogger });
  const r = await guard({ roomName: '', redisCount: 50, alreadyIn: false });
  assert.deepStrictEqual(r, { allowed: false, liveCount: null });
  assert.strictEqual(svc.calls.length, 0);
});
