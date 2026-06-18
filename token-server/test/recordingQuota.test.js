// ============================================================================
// recordingQuota — unit tests (node:test)
//
// Covers isRecordingOverCap (pure predicate) and the sweeper's stop decision with
// fake db / egressClient / redis. No DB/LiveKit/Redis needed.
// ============================================================================

const { test } = require('node:test');
const assert = require('node:assert');
const { isRecordingOverCap, createOverdueRecordingSweeper } = require('../recordingQuota');

const silentLogger = { log() {}, error() {} };

test('isRecordingOverCap: null/invalid cap is never over', () => {
  assert.strictEqual(isRecordingOverCap(99999, null), false);
  assert.strictEqual(isRecordingOverCap(99999, undefined), false);
  assert.strictEqual(isRecordingOverCap(99999, 0), false);
  assert.strictEqual(isRecordingOverCap(99999, -5), false);
  assert.strictEqual(isRecordingOverCap(NaN, 60), false);
});

test('isRecordingOverCap: under vs at/over the cap', () => {
  assert.strictEqual(isRecordingOverCap(59, 60), false);
  assert.strictEqual(isRecordingOverCap(60, 60), true);
  assert.strictEqual(isRecordingOverCap(61, 60), true);
  // numeric-string inputs (pg EXTRACT returns strings)
  assert.strictEqual(isRecordingOverCap('120', '60'), true);
  assert.strictEqual(isRecordingOverCap('30', '60'), false);
});

function makeDeps(activeRows) {
  const stopped = [];
  const updates = [];
  const db = {
    async query(text, params) {
      if (/SELECT id, egress_id/.test(text)) return { rows: activeRows };
      if (/recording_tracks\s+WHERE session_id/.test(text) && /SELECT egress_id/.test(text)) {
        return { rows: [] }; // single-egress sessions (no tracks)
      }
      updates.push({ text: text.trim().split('\n')[0], params });
      return { rows: [] };
    },
  };
  const egressClient = { async stopEgress(id) { stopped.push(id); } };
  const redis = { async hget() { return null; }, async hset() {} };
  const roomKey = (c) => `room:${c}`;
  return { deps: { db, egressClient, redis, roomKey, logger: silentLogger }, stopped, updates };
}

test('sweepOnce stops only over-cap sessions', async () => {
  const { deps, stopped } = makeDeps([
    { id: 's1', egress_id: 'eg1', room_name: 'inter-A', room_code: 'A', max_duration_seconds: 60, elapsed_seconds: '120' },
    { id: 's2', egress_id: 'eg2', room_name: 'inter-B', room_code: 'B', max_duration_seconds: 600, elapsed_seconds: '30' },
    { id: 's3', egress_id: 'eg3', room_name: 'inter-C', room_code: 'C', max_duration_seconds: 60, elapsed_seconds: '60' },
  ]);
  const sweep = createOverdueRecordingSweeper(deps);
  const count = await sweep();
  assert.strictEqual(count, 2, 'only the two at/over-cap sessions are stopped');
  assert.deepStrictEqual(stopped.sort(), ['eg1', 'eg3']);
});

test('sweepOnce is a no-op when nothing is over cap', async () => {
  const { deps, stopped } = makeDeps([
    { id: 's1', egress_id: 'eg1', room_name: 'inter-A', room_code: 'A', max_duration_seconds: 600, elapsed_seconds: '10' },
  ]);
  const sweep = createOverdueRecordingSweeper(deps);
  const count = await sweep();
  assert.strictEqual(count, 0);
  assert.deepStrictEqual(stopped, []);
});

test('sweepOnce continues past a per-session stop failure', async () => {
  const activeRows = [
    { id: 's1', egress_id: 'eg1', room_name: 'inter-A', room_code: 'A', max_duration_seconds: 60, elapsed_seconds: '120' },
    { id: 's2', egress_id: 'eg2', room_name: 'inter-B', room_code: 'B', max_duration_seconds: 60, elapsed_seconds: '120' },
  ];
  const stopped = [];
  const db = {
    async query(text) {
      if (/SELECT id, egress_id/.test(text)) return { rows: activeRows };
      return { rows: [] };
    },
  };
  const egressClient = {
    async stopEgress(id) {
      if (id === 'eg1') throw new Error('livekit down');
      stopped.push(id);
    },
  };
  const redis = { async hget() { return null; }, async hset() {} };
  const sweep = createOverdueRecordingSweeper({ db, egressClient, redis, roomKey: (c) => `room:${c}`, logger: silentLogger });
  const count = await sweep();
  assert.strictEqual(count, 1, 'eg2 still stopped despite eg1 failure');
  assert.deepStrictEqual(stopped, ['eg2']);
});
