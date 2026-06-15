// ============================================================================
// GET/PATCH /auth/profile — integration tests (node:test harness)
//
// Exercises the real profile router + auth stack against the dev DB, seeding
// users directly. Validates partial updates, trimming, IANA timezone
// validation, the language allowlist, and clearing prefs back to null.
// ============================================================================

const { test, after } = require('node:test');
const assert = require('node:assert');
const express = require('express');
const h = require('./helpers');
const auth = require('./../auth');
const redis = require('./../redis');
const profileRouter = require('./../profile');

function buildApp() {
  const app = express();
  app.use(express.json());
  app.use(auth.authenticateToken);
  app.use('/auth', profileRouter);
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

const track = [];

after(async () => {
  await h.cleanupUsers(track);
  await h.db.pool.end();
  redis.disconnect();
});

test('GET/PATCH /auth/profile', async (t) => {
  const { server, baseURL } = await startServer();
  t.after(() => server.close());

  await t.test('requires auth', async () => {
    const g = await h.api(baseURL, { path: '/auth/profile' });
    assert.equal(g.status, 401);
    const p = await h.api(baseURL, { method: 'PATCH', path: '/auth/profile', body: { displayName: 'X' } });
    assert.equal(p.status, 401);
  });

  await t.test('GET returns profile with null prefs by default', async () => {
    const user = await h.createUser(); track.push(user.id);
    const r = await h.api(baseURL, { path: '/auth/profile', token: h.tokenFor(user) });
    assert.equal(r.status, 200);
    assert.equal(r.json.email, user.email);
    assert.equal(r.json.displayName, 'Test User');
    assert.equal(r.json.timezone, null);
    assert.equal(r.json.language, null);
  });

  await t.test('PATCH displayName trims and persists', async () => {
    const user = await h.createUser(); track.push(user.id);
    const r = await h.api(baseURL, {
      method: 'PATCH', path: '/auth/profile', token: h.tokenFor(user),
      body: { displayName: '  New Name  ' },
    });
    assert.equal(r.status, 200);
    assert.equal(r.json.displayName, 'New Name');

    const fresh = await h.api(baseURL, { path: '/auth/profile', token: h.tokenFor(user) });
    assert.equal(fresh.json.displayName, 'New Name', 'persisted');
  });

  await t.test('PATCH rejects blank/oversized displayName', async () => {
    const user = await h.createUser(); track.push(user.id);
    const blank = await h.api(baseURL, {
      method: 'PATCH', path: '/auth/profile', token: h.tokenFor(user),
      body: { displayName: '   ' },
    });
    assert.equal(blank.status, 400);
    const huge = await h.api(baseURL, {
      method: 'PATCH', path: '/auth/profile', token: h.tokenFor(user),
      body: { displayName: 'x'.repeat(101) },
    });
    assert.equal(huge.status, 400);
  });

  await t.test('PATCH timezone validates IANA, accepts clear', async () => {
    const user = await h.createUser(); track.push(user.id);
    const ok = await h.api(baseURL, {
      method: 'PATCH', path: '/auth/profile', token: h.tokenFor(user),
      body: { timezone: 'Asia/Kolkata' },
    });
    assert.equal(ok.status, 200);
    assert.equal(ok.json.timezone, 'Asia/Kolkata');

    const bad = await h.api(baseURL, {
      method: 'PATCH', path: '/auth/profile', token: h.tokenFor(user),
      body: { timezone: 'Not/AZone' },
    });
    assert.equal(bad.status, 400);

    const clear = await h.api(baseURL, {
      method: 'PATCH', path: '/auth/profile', token: h.tokenFor(user),
      body: { timezone: null },
    });
    assert.equal(clear.status, 200);
    assert.equal(clear.json.timezone, null, 'cleared back to system default');
  });

  await t.test('PATCH language allowlist; empty body rejected; partial update untouched fields', async () => {
    const user = await h.createUser(); track.push(user.id);
    const okLang = await h.api(baseURL, {
      method: 'PATCH', path: '/auth/profile', token: h.tokenFor(user),
      body: { language: 'en-US' },
    });
    assert.equal(okLang.status, 200);
    assert.equal(okLang.json.language, 'en-US');

    const badLang = await h.api(baseURL, {
      method: 'PATCH', path: '/auth/profile', token: h.tokenFor(user),
      body: { language: 'xx-XX' },
    });
    assert.equal(badLang.status, 400);

    const empty = await h.api(baseURL, {
      method: 'PATCH', path: '/auth/profile', token: h.tokenFor(user), body: {},
    });
    assert.equal(empty.status, 400, 'nothing to update');

    // Partial update: changing timezone must not clobber language.
    const tz = await h.api(baseURL, {
      method: 'PATCH', path: '/auth/profile', token: h.tokenFor(user),
      body: { timezone: 'America/New_York' },
    });
    assert.equal(tz.json.language, 'en-US', 'language untouched by timezone-only PATCH');
  });
});
