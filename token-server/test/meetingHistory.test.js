// ============================================================================
// GET /meetings/history — integration tests (node:test harness)
//
// Exercises the real scheduling router + auth stack against the dev DB +
// Redis, seeding meetings/meeting_participants directly (the same tables
// /room/create and /room/join write). Validates the status truth policy:
// DB-'active' rows are only 'active' when their Redis room key exists.
// ============================================================================

const { test, after } = require('node:test');
const assert = require('node:assert');
const express = require('express');
const crypto = require('crypto');
const h = require('./helpers');
const auth = require('./../auth');
const redis = require('./../redis');
const schedulingRouter = require('./../scheduling');

function buildApp() {
  const app = express();
  app.use(express.json());
  app.use(auth.authenticateToken);
  app.use('/meetings', schedulingRouter);
  app.use((err, _req, res, _next) => {
    res.status(err.status || 500).json({ error: err.message });
  });
  return app;
}

async function startServer() {
  const app = buildApp();
  const server = await new Promise((resolve) => {
    const s = app.listen(0, '127.0.0.1', () => resolve(s));
  });
  return { server, baseURL: `http://127.0.0.1:${server.address().port}` };
}

const CODE_CHARS = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
function roomCode() {
  let code = '';
  const bytes = crypto.randomBytes(6);
  for (let i = 0; i < 6; i++) code += CODE_CHARS[bytes[i] % CODE_CHARS.length];
  return code;
}

/** Seed a meetings row (the shape /room/create writes). Returns {id, code}. */
async function seedMeeting(hostUser, { status = 'active', startedAgoMin = 60,
                                       endedAfterMin = null, roomType = 'call',
                                       name = 'Test Room' } = {}) {
  const code = roomCode();
  const res = await h.db.query(
    `INSERT INTO meetings (host_user_id, room_code, room_name, room_type, status, started_at, ended_at)
     VALUES ($1, $2, $3, $4, $5,
             NOW() - ($6 || ' minutes')::interval,
             CASE WHEN $7::int IS NULL THEN NULL
                  ELSE NOW() - ($6 || ' minutes')::interval + ($7 || ' minutes')::interval END)
     RETURNING id`,
    [hostUser.id, code, name, roomType, status, String(startedAgoMin), endedAfterMin]
  );
  const id = res.rows[0].id;
  await h.db.query(
    `INSERT INTO meeting_participants (meeting_id, user_id, identity, display_name, role)
     VALUES ($1, $2, $3, $4, 'host')`,
    [id, hostUser.id, `id-${crypto.randomUUID()}`, hostUser.display_name]
  );
  return { id, code };
}

async function addParticipant(meetingId, user, role = 'participant') {
  await h.db.query(
    `INSERT INTO meeting_participants (meeting_id, user_id, identity, display_name, role)
     VALUES ($1, $2, $3, $4, $5)`,
    [meetingId, user ? user.id : null, `id-${crypto.randomUUID()}`,
     user ? user.display_name : 'Guest', role]
  );
}

const track = [];
const redisKeys = [];

after(async () => {
  for (const key of redisKeys) {
    try { await redis.del(key); } catch (_) { /* best-effort */ }
  }
  await h.cleanupUsers(track);
  await h.db.pool.end();
  redis.disconnect();
});

test('GET /meetings/history', async (t) => {
  const { server, baseURL } = await startServer();
  t.after(() => server.close());

  await t.test('requires auth', async () => {
    const r = await h.api(baseURL, { path: '/meetings/history' });
    assert.equal(r.status, 401);
  });

  await t.test('returns hosted + participated meetings, newest first, with roles', async () => {
    const host = await h.createUser(); track.push(host.id);
    const guestUser = await h.createUser(); track.push(guestUser.id);

    // Older meeting hosted by `host`; newer meeting hosted by guestUser where
    // `host` only participated.
    const m1 = await seedMeeting(host, { startedAgoMin: 600, endedAfterMin: 45 });
    const m2 = await seedMeeting(guestUser, { startedAgoMin: 30 });
    await addParticipant(m2.id, host, 'participant');

    const r = await h.api(baseURL, { path: '/meetings/history', token: h.tokenFor(host) });
    assert.equal(r.status, 200);
    const codes = r.json.meetings.map(m => m.roomCode);
    assert.deepEqual(codes, [m2.code, m1.code], 'newest first');

    const mine = Object.fromEntries(r.json.meetings.map(m => [m.roomCode, m]));
    assert.equal(mine[m1.code].role, 'host');
    assert.equal(mine[m2.code].role, 'participant');
    assert.equal(mine[m1.code].durationMinutes, 45, 'duration from ended_at');
    assert.equal(mine[m2.code].durationMinutes, null, 'no fabricated duration');
    assert.equal(mine[m2.code].participantCount, 2, 'host + participant');
  });

  await t.test('DB-active without a Redis room key reads as ended; with key reads active', async () => {
    const host = await h.createUser(); track.push(host.id);
    const zombie = await seedMeeting(host, { startedAgoMin: 120 });          // no Redis key
    const live = await seedMeeting(host, { startedAgoMin: 5 });
    const liveKey = `room:${live.code}`;
    await redis.hset(liveKey, 'roomName', 'live-room');
    redisKeys.push(liveKey);

    const r = await h.api(baseURL, { path: '/meetings/history', token: h.tokenFor(host) });
    const byCode = Object.fromEntries(r.json.meetings.map(m => [m.roomCode, m]));
    assert.equal(byCode[zombie.code].status, 'ended', 'zombie reported ended');
    assert.equal(byCode[live.code].status, 'active', 'live room stays active');
  });

  await t.test('failed meetings are excluded; other users see nothing', async () => {
    const host = await h.createUser(); track.push(host.id);
    const outsider = await h.createUser(); track.push(outsider.id);
    await seedMeeting(host, { status: 'failed' });
    await seedMeeting(host, { startedAgoMin: 10 });

    const mineR = await h.api(baseURL, { path: '/meetings/history', token: h.tokenFor(host) });
    assert.equal(mineR.json.meetings.length, 1, 'failed row hidden');

    const theirsR = await h.api(baseURL, { path: '/meetings/history', token: h.tokenFor(outsider) });
    assert.equal(theirsR.json.meetings.length, 0, 'not a member of any meeting');
  });

  await t.test('respects limit', async () => {
    const host = await h.createUser(); track.push(host.id);
    for (let i = 0; i < 3; i++) {
      await seedMeeting(host, { startedAgoMin: 100 + i });
    }
    const r = await h.api(baseURL, { path: '/meetings/history?limit=2', token: h.tokenFor(host) });
    assert.equal(r.json.meetings.length, 2);
  });
});
