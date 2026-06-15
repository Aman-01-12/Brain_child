// Integration tests — Teams chat REST mitigations, against the live dev DB+Redis.
// Mounts the real teams router behind real authenticateToken; seeds real users,
// teams, and access tokens. Each test maps to a Critical/High finding and fails
// if that mitigation is removed.

require('dotenv').config();

const { test, describe, before, after } = require('node:test');
const assert = require('node:assert');
const crypto = require('crypto');
const h = require('./helpers');

// Close shared singletons (pg pool, eager ioredis connection) after the whole
// file so the test process exits instead of hanging on open handles.
after(async () => {
  await h.db.pool.end().catch(() => {});
  try { require('./../redis').disconnect(); } catch { /* already closed */ }
});

describe('Teams chat — Critical/High REST mitigations', () => {
  const ctx = {};
  const userIds = [];

  before(async () => {
    const s = await h.startServer();
    ctx.server = s.server;
    ctx.baseURL = s.baseURL;

    ctx.owner = await h.createUser();           userIds.push(ctx.owner.id);
    ctx.member = await h.createUser();           userIds.push(ctx.member.id);
    ctx.outsider = await h.createUser();         userIds.push(ctx.outsider.id);
    ctx.removable = await h.createUser();        userIds.push(ctx.removable.id);
    ctx.addee = await h.createUser();            userIds.push(ctx.addee.id);

    ctx.ownerTok = h.tokenFor(ctx.owner);
    ctx.memberTok = h.tokenFor(ctx.member);
    ctx.outsiderTok = h.tokenFor(ctx.outsider);
    ctx.removableTok = h.tokenFor(ctx.removable);

    ctx.teamId = await h.createTeam(ctx.owner);
    await h.addMember(ctx.teamId, ctx.member);
    await h.addMember(ctx.teamId, ctx.removable);

    // A second team the OWNER also belongs to — used for the H4 composite-key test.
    ctx.otherTeamId = await h.createTeam(ctx.outsider);
    await h.addMember(ctx.otherTeamId, ctx.owner);
    // A file that lives in teamId (NOT in otherTeamId).
    ctx.fileInTeamId = await h.insertFile(ctx.teamId, ctx.owner.id);
  });

  after(async () => {
    if (ctx.server) await new Promise((r) => ctx.server.close(r));
    await h.cleanupUsers(userIds);
  });

  // ---- C1: cross-tenant read (IDOR) ------------------------------------
  test('C1: a non-member cannot read team messages (403)', async () => {
    const r = await h.api(ctx.baseURL, { path: `/teams/${ctx.teamId}/messages`, token: ctx.outsiderTok });
    assert.strictEqual(r.status, 403);
  });

  test('C1: an active member can read team messages (200)', async () => {
    const r = await h.api(ctx.baseURL, { path: `/teams/${ctx.teamId}/messages`, token: ctx.memberTok });
    assert.strictEqual(r.status, 200);
    assert.ok(Array.isArray(r.json.messages));
  });

  test('C1: a non-member cannot post to a team (403)', async () => {
    const r = await h.api(ctx.baseURL, {
      method: 'POST', path: `/teams/${ctx.teamId}/messages`, token: ctx.outsiderTok, body: { body: 'hi' },
    });
    assert.strictEqual(r.status, 403);
  });

  // ---- H7: message validation / injection surface ----------------------
  test('H7: empty/whitespace message is rejected (400)', async () => {
    const r = await h.api(ctx.baseURL, {
      method: 'POST', path: `/teams/${ctx.teamId}/messages`, token: ctx.memberTok, body: { body: '   ' },
    });
    assert.strictEqual(r.status, 400);
  });

  test('H7: oversized message (>4000 chars) is rejected (400)', async () => {
    const r = await h.api(ctx.baseURL, {
      method: 'POST', path: `/teams/${ctx.teamId}/messages`, token: ctx.memberTok, body: { body: 'x'.repeat(4001) },
    });
    assert.strictEqual(r.status, 400);
  });

  test('H7: a valid message is accepted (201) and persisted', async () => {
    const r = await h.api(ctx.baseURL, {
      method: 'POST', path: `/teams/${ctx.teamId}/messages`, token: ctx.memberTok, body: { body: 'hello team' },
    });
    assert.strictEqual(r.status, 201);
    assert.strictEqual(r.json.body, 'hello team');
    assert.strictEqual(r.json.kind, 'text');
  });

  // ---- H10: idempotency / duplicate suppression ------------------------
  test('H10: replaying the same idempotency key yields one message', async () => {
    const key = crypto.randomUUID();
    const body = { body: `idem-${key}` };
    const r1 = await h.api(ctx.baseURL, { method: 'POST', path: `/teams/${ctx.teamId}/messages`, token: ctx.memberTok, body, idemKey: key });
    const r2 = await h.api(ctx.baseURL, { method: 'POST', path: `/teams/${ctx.teamId}/messages`, token: ctx.memberTok, body, idemKey: key });
    assert.strictEqual(r1.status, 201);
    assert.ok(r2.status === 201 || r2.status === 200);
    assert.strictEqual(r1.json.id, r2.json.id, 'duplicate must return the same message id');

    const count = await h.db.query(
      `SELECT COUNT(*)::int AS n FROM team_messages WHERE team_id = $1 AND body = $2`,
      [ctx.teamId, body.body]
    );
    assert.strictEqual(count.rows[0].n, 1, 'exactly one row must persist for a replayed key');
  });

  // ---- C3: stale authorization after removal ---------------------------
  test('C3: a removed member is immediately denied REST access (403)', async () => {
    // Precondition: the removable member can read.
    let r = await h.api(ctx.baseURL, { path: `/teams/${ctx.teamId}/messages`, token: ctx.removableTok });
    assert.strictEqual(r.status, 200);

    // Owner removes them via the real route.
    const mid = await h.memberMid(ctx.teamId, ctx.removable.id);
    r = await h.api(ctx.baseURL, { method: 'DELETE', path: `/teams/${ctx.teamId}/members/${mid}`, token: ctx.ownerTok });
    assert.strictEqual(r.status, 200);

    // Post-removal: membership is re-checked on every REST call.
    r = await h.api(ctx.baseURL, { path: `/teams/${ctx.teamId}/messages`, token: ctx.removableTok });
    assert.strictEqual(r.status, 403);
  });

  // ---- H4: file download IDOR (composite key) --------------------------
  test('H4: a non-member cannot get a file URL for that team (403)', async () => {
    const r = await h.api(ctx.baseURL, {
      path: `/teams/${ctx.teamId}/files/${ctx.fileInTeamId}/url`, token: ctx.outsiderTok,
    });
    assert.strictEqual(r.status, 403);
  });

  test('H4: a member of team B cannot fetch team A\u2019s file via team B (404)', async () => {
    // Owner IS a member of otherTeamId, but the file lives in teamId — composite
    // (team_id + fileId) lookup must miss → 404, never leak the object.
    const r = await h.api(ctx.baseURL, {
      path: `/teams/${ctx.otherTeamId}/files/${ctx.fileInTeamId}/url`, token: ctx.ownerTok,
    });
    assert.strictEqual(r.status, 404);
  });

  test('H4: a member CAN reach their own team\u2019s file (authorization passes)', async () => {
    const r = await h.api(ctx.baseURL, {
      path: `/teams/${ctx.teamId}/files/${ctx.fileInTeamId}/url`, token: ctx.ownerTok,
    });
    // 200 when AWS creds resolve (offline presign), 500 only if creds are absent.
    // Either way authorization PASSED — the security-relevant assertion.
    assert.ok(r.status !== 403 && r.status !== 404, `expected auth to pass, got ${r.status}`);
  });

  // ---- H9: instant-add enumeration controls ----------------------------
  test('H9: a non-member cannot add members (403)', async () => {
    const r = await h.api(ctx.baseURL, {
      method: 'POST', path: `/teams/${ctx.teamId}/members`, token: ctx.outsiderTok, body: { email: ctx.addee.email },
    });
    assert.strictEqual(r.status, 403);
  });

  test('H9: a plain member (not owner/admin) cannot add members (403)', async () => {
    const r = await h.api(ctx.baseURL, {
      method: 'POST', path: `/teams/${ctx.teamId}/members`, token: ctx.memberTok, body: { email: ctx.addee.email },
    });
    assert.strictEqual(r.status, 403);
  });

  test('H9: owner adds a registered user (201)', async () => {
    const r = await h.api(ctx.baseURL, {
      method: 'POST', path: `/teams/${ctx.teamId}/members`, token: ctx.ownerTok, body: { email: ctx.addee.email },
    });
    assert.strictEqual(r.status, 201);
    assert.strictEqual(r.json.member.userId, ctx.addee.id);
  });

  test('H9: owner adding an unregistered email gets "No Inter account" (404)', async () => {
    const r = await h.api(ctx.baseURL, {
      method: 'POST', path: `/teams/${ctx.teamId}/members`, token: ctx.ownerTok,
      body: { email: `ghost-${crypto.randomUUID()}@test.invalid` },
    });
    assert.strictEqual(r.status, 404);
    assert.strictEqual(r.json.code, 'NO_INTER_ACCOUNT');
  });
});

// ---- H8: per-user-per-team message rate limit (isolated principal) -----
describe('H8: message flooding rate limit', () => {
  const ctx = {};
  const userIds = [];

  before(async () => {
    const s = await h.startServer();
    ctx.server = s.server; ctx.baseURL = s.baseURL;
    const fx = await h.isolatedTeam(userIds);
    ctx.token = fx.token; ctx.teamId = fx.teamId;
  });

  after(async () => {
    if (ctx.server) await new Promise((r) => ctx.server.close(r));
    await h.cleanupUsers(userIds);
  });

  test('the 61st message within the window returns 429', async () => {
    let sawOk = false;
    let saw429 = false;
    for (let i = 0; i < 61; i++) {
      const r = await h.api(ctx.baseURL, {
        method: 'POST', path: `/teams/${ctx.teamId}/messages`, token: ctx.token, body: { body: `flood ${i}` },
      });
      if (r.status === 201) sawOk = true;
      if (r.status === 429) { saw429 = true; break; }
    }
    assert.ok(sawOk, 'early messages should succeed');
    assert.ok(saw429, 'flood must eventually be rate-limited (429)');
  });
});

// ---- H9 (rate limit): add-by-email enumeration cap (isolated principal) -
describe('H9: add-by-email rate limit', () => {
  const ctx = {};
  const userIds = [];

  before(async () => {
    const s = await h.startServer();
    ctx.server = s.server; ctx.baseURL = s.baseURL;
    const fx = await h.isolatedTeam(userIds);
    ctx.token = fx.token; ctx.teamId = fx.teamId;
  });

  after(async () => {
    if (ctx.server) await new Promise((r) => ctx.server.close(r));
    await h.cleanupUsers(userIds);
  });

  test('repeated add attempts are rate-limited (429) before 31 tries', async () => {
    let saw429 = false;
    for (let i = 0; i < 31; i++) {
      // Unregistered emails → 404, but the rate-limit check runs first and counts.
      const r = await h.api(ctx.baseURL, {
        method: 'POST', path: `/teams/${ctx.teamId}/members`, token: ctx.token,
        body: { email: `enum-${i}-${crypto.randomUUID()}@test.invalid` },
      });
      if (r.status === 429) { saw429 = true; break; }
    }
    assert.ok(saw429, 'enumeration attempts must be rate-limited (429)');
  });
});
