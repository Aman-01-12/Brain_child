// ============================================================================
// Interview tier gate — integration tests (node:test harness)
//
// Verifies the SERVER-SIDE enforcement (not just the client gate) that hosting
// or scheduling an INTERVIEW requires the `hiring` tier. These tests exercise
// the real handlers + real auth stack against the dev DB + Redis:
//
//   POST /room/create        (in index.js app)        — roomType:'interview'
//   POST /meetings/schedule  (scheduling router)       — roomType:'interview'
//
// The gate fires BEFORE any LiveKit / room-creation side effect, so the
// blocked (403) cases are fully deterministic and require no LiveKit. These are
// the regression tests for Finding #1 of the tier-centralization review: if the
// guard block were removed, a non-hiring user would no longer get 403
// INSUFFICIENT_TIER and these tests would fail.
// ============================================================================

require('dotenv').config();

const { test, after } = require('node:test');
const assert = require('node:assert');
const express = require('express');
const h = require('./helpers');
const auth = require('./../auth');
const redis = require('./../redis');
const schedulingRouter = require('./../scheduling');
const { app: mainApp } = require('./../index'); // require.main guard ⇒ no port bound

// Standalone app mounting the REAL scheduling router behind the REAL auth stack
// (mirrors meetingHistory.test.js). Used for the /meetings/schedule gate.
function buildScheduleApp() {
  const app = express();
  app.use(express.json());
  app.use(auth.authenticateToken);
  app.use('/meetings', schedulingRouter);
  app.use((err, _req, res, _next) => {
    res.status(err.status || 500).json({ error: err.message });
  });
  return app;
}

async function listen(app) {
  const server = await new Promise((resolve) => {
    const s = app.listen(0, '127.0.0.1', () => resolve(s));
  });
  return { server, baseURL: `http://127.0.0.1:${server.address().port}` };
}

function futureISO(daysAhead = 1) {
  return new Date(Date.now() + daysAhead * 24 * 60 * 60 * 1000).toISOString();
}

const track = [];

after(async () => {
  // Remove any scheduled_meetings created by the positive "passes the gate"
  // cases before deleting users (robust even if the FK does not cascade).
  if (track.length) {
    try {
      await h.db.query('DELETE FROM scheduled_meetings WHERE host_user_id = ANY($1)', [track]);
    } catch (_) { /* best-effort */ }
  }
  await h.cleanupUsers(track);
  await h.db.pool.end();
  redis.disconnect();
});

test('POST /room/create — interview hosting is server-gated to hiring', async (t) => {
  const { server, baseURL } = await listen(mainApp);
  t.after(() => server.close());

  await t.test('free user creating an interview is blocked (403 INSUFFICIENT_TIER)', async () => {
    const u = await h.createUser({ tier: 'free' }); track.push(u.id);
    const r = await h.api(baseURL, {
      method: 'POST', path: '/room/create', token: h.tokenFor(u),
      body: { identity: 'host-1', displayName: 'Host', roomType: 'interview' },
    });
    assert.equal(r.status, 403);
    assert.equal(r.json.code, 'INSUFFICIENT_TIER');
    assert.equal(r.json.requiredTier, 'hiring');
  });

  await t.test('pro user creating an interview is blocked (403 INSUFFICIENT_TIER)', async () => {
    const u = await h.createUser({ tier: 'pro' }); track.push(u.id);
    const r = await h.api(baseURL, {
      method: 'POST', path: '/room/create', token: h.tokenFor(u),
      body: { identity: 'host-2', displayName: 'Host', roomType: 'interview' },
    });
    assert.equal(r.status, 403);
    assert.equal(r.json.code, 'INSUFFICIENT_TIER');
    assert.equal(r.json.currentTier, 'pro');
  });

  await t.test('unauthenticated request is rejected', async () => {
    const r = await h.api(baseURL, {
      method: 'POST', path: '/room/create',
      body: { identity: 'host-5', displayName: 'Host', roomType: 'interview' },
    });
    assert.equal(r.status, 401);
  });
});

test('POST /meetings/schedule — scheduling an interview is server-gated to hiring', async (t) => {
  const { server, baseURL } = await listen(buildScheduleApp());
  t.after(() => server.close());

  const baseBody = () => ({
    title: 'Tier gate test',
    scheduledAt: futureISO(1),
    durationMinutes: 30,
    hostTimezone: 'America/New_York',
  });

  await t.test('pro user scheduling an interview is blocked (403 INSUFFICIENT_TIER)', async () => {
    const u = await h.createUser({ tier: 'pro' }); track.push(u.id);
    const r = await h.api(baseURL, {
      method: 'POST', path: '/meetings/schedule', token: h.tokenFor(u),
      body: { ...baseBody(), roomType: 'interview' },
    });
    assert.equal(r.status, 403);
    assert.equal(r.json.code, 'INSUFFICIENT_TIER');
    assert.equal(r.json.requiredTier, 'hiring');
  });

  await t.test('hiring user scheduling an interview passes the tier gate', async () => {
    const u = await h.createUser({ tier: 'hiring' }); track.push(u.id);
    const r = await h.api(baseURL, {
      method: 'POST', path: '/meetings/schedule', token: h.tokenFor(u),
      body: { ...baseBody(), roomType: 'interview' },
    });
    assert.notEqual(r.json && r.json.code, 'INSUFFICIENT_TIER');
  });

  await t.test('pro user scheduling a plain call is NOT blocked by the interview gate', async () => {
    const u = await h.createUser({ tier: 'pro' }); track.push(u.id);
    const r = await h.api(baseURL, {
      method: 'POST', path: '/meetings/schedule', token: h.tokenFor(u),
      body: { ...baseBody(), roomType: 'call' },
    });
    assert.notEqual(r.json && r.json.code, 'INSUFFICIENT_TIER');
  });
});
