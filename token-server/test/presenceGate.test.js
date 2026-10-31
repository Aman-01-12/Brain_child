// ============================================================================
// presenceGate — integration tests (node:test). PRESENCE MONITORING (provisional)
//
// Exercises the REAL /presence router, the REAL auth stack and the REAL room
// state against the dev Postgres + Redis, following test/interviewTierGate.js
// as the harness template (dotenv, import { app } from ./index — the
// require.main guard means no port is bound — then app.listen(0)).
//
// Two groups:
//   GROUP A — master flag OFF. This is the zero-impact proof: the whole
//             /presence surface answers 404, no presence key reaches the room
//             hash, and /room/join's response carries no presence key. A
//             reviewer should be able to read this group and conclude "flag off
//             means a server indistinguishable from the one before this
//             feature".
//   GROUP B — master flag ON. The tier gate, the consent record, the ingest
//             contract, the moderator cross-check, the note rule and the export.
//
// The config getters read process.env at call time, so Group B simply sets the
// variable — no module reload.
//
// Cleanup: the Redis room keys and the interview_presence_sessions rows (events
// and notes cascade) go in after(), before cleanupUsers. The audit_events rows
// are NOT cleaned up and must not be: migration 011 forbids DELETE at the
// database. The tests therefore assert their presence only.
// ============================================================================

require('dotenv').config();

const { test, after } = require('node:test');
const assert = require('node:assert');
const nodeCrypto = require('node:crypto');
const h = require('./helpers');
const redis = require('./../redis');
const { findForbiddenKey } = require('./../presenceEvents');
const { app } = require('./../index'); // require.main guard ⇒ no port bound

const CODE_CHARS = 'ABCDEFGHJKLMNPQRSTUVWXYZ234567';
const PRESENCE_PATHS = [
  { method: 'POST', path: '/presence/consent' },
  { method: 'POST', path: '/presence/events' },
  { method: 'GET',  path: '/presence/timeline/ABCDEF/cand-1' },
  { method: 'POST', path: '/presence/timeline/ABCDEF/cand-1/note' },
  { method: 'GET',  path: '/presence/export/ABCDEF/cand-1' },
];

const track = [];      // user ids to delete
const roomCodes = [];  // room codes whose Redis + DB state to delete

function randomCode() {
  let code = '';
  const bytes = nodeCrypto.randomBytes(6);
  for (let i = 0; i < 6; i++) code += CODE_CHARS[bytes[i] % CODE_CHARS.length];
  return code;
}

async function listen(a) {
  const server = await new Promise((resolve) => {
    const s = a.listen(0, '127.0.0.1', () => resolve(s));
  });
  return { server, baseURL: `http://127.0.0.1:${server.address().port}` };
}

/// Minimal fetch wrapper that can carry the Leave-Token header (h.api cannot).
async function req(baseURL, { method = 'GET', path, token, leaveToken, body } = {}) {
  const headers = {};
  if (token) headers['Authorization'] = `Bearer ${token}`;
  if (leaveToken) headers['Leave-Token'] = leaveToken;
  const opts = { method, headers };
  if (body !== undefined) {
    headers['Content-Type'] = 'application/json';
    headers['X-Idempotency-Key'] = nodeCrypto.randomUUID();
    opts.body = JSON.stringify(body);
  }
  const res = await fetch(`${baseURL}${path}`, opts);
  const text = await res.text();
  let json = null;
  try { json = JSON.parse(text); } catch { /* non-JSON (CSV) */ }
  return { status: res.status, json, text, contentType: res.headers.get('content-type') };
}

/// Seed a room hash exactly as /room/create would, so an assertion is about the
/// presence gate rather than about room creation (which needs LiveKit).
async function seedRoom({ hostIdentity, hostTier = 'hiring', roomType = 'interview', armed = true, presence = {} }) {
  const code = randomCode();
  roomCodes.push(code);
  const fields = {
    roomName: `inter-${code}`,
    createdAt: String(Date.now()),
    hostIdentity,
    roomType,
    hostTier,
    meetingDisplayName: '',
    muteOnJoin: 'false',
    cameraOffOnJoin: 'false',
    joinBeforeHost: 'true',
    allowUnmuting: 'true',
    chatPermissions: 'everyone',
    sharingPermissions: 'hostOnly',
    shareConflictPolicy: 'oneattime',
    autoRecord: 'false',
    autoTranscript: 'false',
    lobbyEnabled: 'false',
    passwordHash: '',
  };
  if (armed) {
    Object.assign(fields, {
      presenceMonitoringArmed: 'true',
      presenceRegionEU: 'false',
      presenceUnder18: 'false',
      presenceMultipleFacesEnabled: 'false',
      presenceDetectorVersion: 'presence-1.0.0',
      presenceThresholds: JSON.stringify({ faceAbsentOpenMs: 10000, closeMs: 1000 }),
    }, presence);
  }
  await redis.hset(`room:${code}`, fields);
  await redis.expire(`room:${code}`, 3600);
  return code;
}

async function bindModerator(code, identity, userId, role = 'interviewer') {
  await redis.hset(`room:${code}:roles`, identity, role);
  await redis.hset(`room:${code}:user-binding`, identity, String(userId));
}

async function waitForAudit(eventType, roomCode, timeoutMs = 3000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const r = await h.db.query(
      `SELECT event_type FROM audit_events
       WHERE event_type = $1 AND metadata->>'roomCode' = $2 LIMIT 1`,
      [eventType, roomCode]
    );
    if (r.rows.length > 0) return true;
    await new Promise((res) => setTimeout(res, 50));
  }
  return false;
}

function presenceKeysOf(obj) {
  return Object.keys(obj || {}).filter((k) => k.toLowerCase().startsWith('presence'));
}

after(async () => {
  if (roomCodes.length) {
    try {
      // Events and notes cascade from the session row.
      await h.db.query('DELETE FROM interview_presence_sessions WHERE room_code = ANY($1)', [roomCodes]);
    } catch (_) { /* best-effort */ }
    for (const code of roomCodes) {
      try {
        const leaveKeys = await redis.keys(`room:${code}:leavetoken:*`);
        const keys = [
          `room:${code}`, `room:${code}:participants`, `room:${code}:roles`,
          `room:${code}:names`, `room:${code}:user-binding`, `room:${code}:banned`,
          `room:${code}:lobby`, `room:${code}:lobby:names`,
          ...leaveKeys,
        ];
        await redis.del(...keys);
      } catch (_) { /* best-effort */ }
    }
  }
  await h.cleanupUsers(track);
  await h.db.pool.end();
  redis.disconnect();
});

// ===========================================================================
// GROUP A — master flag OFF: the zero-impact proof
// ===========================================================================
test('GROUP A — with PRESENCE_MONITORING_ENABLED unset the feature does not exist', async (t) => {
  delete process.env.PRESENCE_MONITORING_ENABLED;
  const { server, baseURL } = await listen(app);
  t.after(() => server.close());

  await t.test('every /presence path returns 404 PRESENCE_DISABLED', async () => {
    for (const { method, path } of PRESENCE_PATHS) {
      const r = await req(baseURL, {
        method, path,
        body: method === 'POST' ? { roomCode: 'ABCDEF', identity: 'cand-1' } : undefined,
      });
      assert.strictEqual(r.status, 404, `${method} ${path}`);
      assert.strictEqual(r.json.code, 'PRESENCE_DISABLED', `${method} ${path}`);
    }
  });

  await t.test('an authenticated hiring moderator is refused the same way', async () => {
    const u = await h.createUser({ tier: 'hiring' }); track.push(u.id);
    const r = await req(baseURL, {
      method: 'GET',
      path: '/presence/timeline/ABCDEF/cand-1?callerIdentity=host-1',
      token: h.tokenFor(u),
    });
    assert.strictEqual(r.status, 404);
    assert.strictEqual(r.json.code, 'PRESENCE_DISABLED');
  });

  await t.test('a created interview room has no presence key in its Redis hash', async (t2) => {
    const u = await h.createUser({ tier: 'hiring' }); track.push(u.id);
    const created = await req(baseURL, {
      method: 'POST', path: '/room/create', token: h.tokenFor(u),
      body: {
        identity: `host-${nodeCrypto.randomUUID()}`, displayName: 'Host',
        roomType: 'interview', presenceMonitoring: true,
      },
    });
    if (created.status === 503) {
      t2.skip('LiveKit dev server unreachable — /room/create cannot be exercised');
      return;
    }
    assert.strictEqual(created.status, 200, JSON.stringify(created.json));
    const code = created.json.roomCode;
    roomCodes.push(code);

    const hash = await redis.hgetall(`room:${code}`);
    assert.deepStrictEqual(presenceKeysOf(hash), [],
      'with the flag off the room hash must be byte-identical to a pre-feature room');

    const joined = await req(baseURL, {
      method: 'POST', path: '/room/join',
      body: { roomCode: code, identity: `cand-${nodeCrypto.randomUUID()}`, displayName: 'Candidate' },
    });
    assert.strictEqual(joined.status, 200, JSON.stringify(joined.json));
    assert.deepStrictEqual(presenceKeysOf(joined.json), [],
      'with the flag off /room/join must not mention presence at all');
  });

  await t.test('a room armed before the flag was turned off can record nothing', async () => {
    // A room hash can only carry presenceMonitoringArmed if it was created
    // while the flag was on, and it expires with the room (24 h). Turning the
    // flag off takes the whole recording surface away immediately: the client
    // may still read "armed" from its join response, but consent cannot be
    // granted and no event can be stored, so nothing is ever collected.
    const code = await seedRoom({ hostIdentity: 'host-A', hostTier: 'hiring' });
    const identity = `cand-${nodeCrypto.randomUUID()}`;
    const joined = await req(baseURL, {
      method: 'POST', path: '/room/join',
      body: { roomCode: code, identity, displayName: 'Candidate' },
    });
    assert.strictEqual(joined.status, 200);

    const consent = await req(baseURL, {
      method: 'POST', path: '/presence/consent', leaveToken: joined.json.leaveToken,
      body: { roomCode: code, identity, decision: 'grant' },
    });
    assert.strictEqual(consent.status, 404);
    assert.strictEqual(consent.json.code, 'PRESENCE_DISABLED');

    const ingest = await req(baseURL, {
      method: 'POST', path: '/presence/events', leaveToken: joined.json.leaveToken,
      body: { roomCode: code, identity, events: [] },
    });
    assert.strictEqual(ingest.status, 404);
    assert.strictEqual(ingest.json.code, 'PRESENCE_DISABLED');

    const rows = await h.db.query(
      'SELECT count(*)::int AS n FROM interview_presence_sessions WHERE room_code = $1', [code]
    );
    assert.strictEqual(rows.rows[0].n, 0, 'not one row is written while the flag is off');
  });
});

// ===========================================================================
// GROUP B — master flag ON
// ===========================================================================
test('GROUP B — with the flag on, the gates, the record and the review surface', async (t) => {
  process.env.PRESENCE_MONITORING_ENABLED = 'true';
  const { server, baseURL } = await listen(app);
  t.after(() => {
    server.close();
    delete process.env.PRESENCE_MONITORING_ENABLED;
  });

  await t.test('a pro host cannot create an interview at all (403 INSUFFICIENT_TIER)', async () => {
    const u = await h.createUser({ tier: 'pro' }); track.push(u.id);
    const r = await req(baseURL, {
      method: 'POST', path: '/room/create', token: h.tokenFor(u),
      body: {
        identity: `host-${nodeCrypto.randomUUID()}`, displayName: 'Host',
        roomType: 'interview', presenceMonitoring: true,
      },
    });
    assert.strictEqual(r.status, 403);
    assert.strictEqual(r.json.code, 'INSUFFICIENT_TIER');
    assert.strictEqual(r.json.requiredTier, 'hiring');
  });

  await t.test('a pro-hosted CALL room never arms, even when asked', async (t2) => {
    const u = await h.createUser({ tier: 'pro' }); track.push(u.id);
    const created = await req(baseURL, {
      method: 'POST', path: '/room/create', token: h.tokenFor(u),
      body: {
        identity: `host-${nodeCrypto.randomUUID()}`, displayName: 'Host',
        roomType: 'call', presenceMonitoring: true,
      },
    });
    if (created.status === 503) {
      t2.skip('LiveKit dev server unreachable — /room/create cannot be exercised');
      return;
    }
    assert.strictEqual(created.status, 200, JSON.stringify(created.json));
    roomCodes.push(created.json.roomCode);
    const hash = await redis.hgetall(`room:${created.json.roomCode}`);
    assert.strictEqual(hash.presenceMonitoringArmed, undefined);
    assert.deepStrictEqual(presenceKeysOf(hash), []);
  });

  await t.test('a hiring interview room arms, and EU / under-18 each force it off', async (t2) => {
    const u = await h.createUser({ tier: 'hiring' }); track.push(u.id);
    const token = h.tokenFor(u);

    const create = async (body) => req(baseURL, {
      method: 'POST', path: '/room/create', token,
      body: { identity: `host-${nodeCrypto.randomUUID()}`, displayName: 'Host', roomType: 'interview', ...body },
    });

    const armed = await create({ presenceMonitoring: true });
    if (armed.status === 503) {
      t2.skip('LiveKit dev server unreachable — /room/create cannot be exercised');
      return;
    }
    assert.strictEqual(armed.status, 200, JSON.stringify(armed.json));
    roomCodes.push(armed.json.roomCode);
    const armedHash = await redis.hgetall(`room:${armed.json.roomCode}`);
    assert.strictEqual(armedHash.presenceMonitoringArmed, 'true');
    assert.strictEqual(armedHash.presenceDetectorVersion, 'presence-1.0.0');
    assert.ok(JSON.parse(armedHash.presenceThresholds).faceAbsentOpenMs > 0);

    const joined = await req(baseURL, {
      method: 'POST', path: '/room/join',
      body: { roomCode: armed.json.roomCode, identity: `cand-${nodeCrypto.randomUUID()}`, displayName: 'Candidate' },
    });
    assert.strictEqual(joined.json.presenceMonitoringArmed, true);
    assert.strictEqual(joined.json.presenceRetentionDays, 90);
    assert.strictEqual(joined.json.presenceMultipleFacesEnabled, false);
    assert.ok(joined.json.presenceRightsContact.length > 0);

    const eu = await create({ presenceMonitoring: true, candidateRegionEU: true });
    assert.strictEqual(eu.status, 200);
    roomCodes.push(eu.json.roomCode);
    assert.deepStrictEqual(presenceKeysOf(await redis.hgetall(`room:${eu.json.roomCode}`)), [],
      'an EU-resident candidate is never monitored');

    const minor = await create({ presenceMonitoring: true, candidateUnder18: true });
    assert.strictEqual(minor.status, 200);
    roomCodes.push(minor.json.roomCode);
    assert.deepStrictEqual(presenceKeysOf(await redis.hgetall(`room:${minor.json.roomCode}`)), [],
      'an under-18 candidate is never monitored');

    const notRequested = await create({});
    assert.strictEqual(notRequested.status, 200);
    roomCodes.push(notRequested.json.roomCode);
    assert.deepStrictEqual(presenceKeysOf(await redis.hgetall(`room:${notRequested.json.roomCode}`)), []);
  });

  await t.test('ingest into a pro-hosted room is 403 INSUFFICIENT_TIER', async () => {
    // The room hash is seeded so the assertion is about the PRESENCE gate, not
    // about /room/create's gate: host tier decides, read from the snapshot.
    const code = await seedRoom({ hostIdentity: 'host-pro', hostTier: 'pro' });
    const identity = `cand-${nodeCrypto.randomUUID()}`;
    const joined = await req(baseURL, {
      method: 'POST', path: '/room/join',
      body: { roomCode: code, identity, displayName: 'Candidate' },
    });
    assert.strictEqual(joined.status, 200);

    const r = await req(baseURL, {
      method: 'POST', path: '/presence/events', leaveToken: joined.json.leaveToken,
      body: { roomCode: code, identity, events: [] },
    });
    assert.strictEqual(r.status, 403);
    assert.strictEqual(r.json.code, 'INSUFFICIENT_TIER');
    assert.strictEqual(r.json.requiredTier, 'hiring');
  });

  await t.test('a missing or wrong Leave-Token is 403 PRESENCE_UNAUTHORIZED', async () => {
    const code = await seedRoom({ hostIdentity: 'host-lt', hostTier: 'hiring' });
    const identity = `cand-${nodeCrypto.randomUUID()}`;
    const joined = await req(baseURL, {
      method: 'POST', path: '/room/join',
      body: { roomCode: code, identity, displayName: 'Candidate' },
    });
    assert.strictEqual(joined.status, 200);

    const missing = await req(baseURL, {
      method: 'POST', path: '/presence/events',
      body: { roomCode: code, identity, events: [] },
    });
    assert.strictEqual(missing.status, 403);
    assert.strictEqual(missing.json.code, 'PRESENCE_UNAUTHORIZED');

    const wrong = await req(baseURL, {
      method: 'POST', path: '/presence/events', leaveToken: 'f'.repeat(64),
      body: { roomCode: code, identity, events: [] },
    });
    assert.strictEqual(wrong.status, 403);
    assert.strictEqual(wrong.json.code, 'PRESENCE_UNAUTHORIZED');

    const otherIdentity = await req(baseURL, {
      method: 'POST', path: '/presence/events', leaveToken: joined.json.leaveToken,
      body: { roomCode: code, identity: `someone-else-${nodeCrypto.randomUUID()}`, events: [] },
    });
    assert.strictEqual(otherIdentity.status, 403,
      'a valid token for one identity must not authorise another');
    assert.strictEqual(otherIdentity.json.code, 'PRESENCE_UNAUTHORIZED');
  });

  await t.test('a declining candidate joins successfully with monitoring off', async () => {
    const hostUser = await h.createUser({ tier: 'hiring' }); track.push(hostUser.id);
    const hostIdentity = `host-${nodeCrypto.randomUUID()}`;
    const code = await seedRoom({ hostIdentity, hostTier: 'hiring' });
    await bindModerator(code, hostIdentity, hostUser.id);

    const identity = `cand-${nodeCrypto.randomUUID()}`;
    const joined = await req(baseURL, {
      method: 'POST', path: '/room/join',
      body: { roomCode: code, identity, displayName: 'Candidate' },
    });
    assert.strictEqual(joined.status, 200, 'declining happens AFTER a successful join');
    assert.ok(joined.json.token, 'the candidate still gets a media token');
    assert.strictEqual(joined.json.presenceMonitoringArmed, true);

    const consent = await req(baseURL, {
      method: 'POST', path: '/presence/consent', leaveToken: joined.json.leaveToken,
      body: { roomCode: code, identity, decision: 'decline' },
    });
    assert.strictEqual(consent.status, 200);
    assert.strictEqual(consent.json.monitoringEnabled, false);
    assert.strictEqual(consent.json.consentState, 'declined');

    const row = await h.db.query(
      `SELECT monitoring_enabled, consent_state, consent_declined_at, detector_version, purge_after
       FROM interview_presence_sessions WHERE room_code = $1 AND participant_identity = $2`,
      [code, identity]
    );
    assert.strictEqual(row.rows.length, 1);
    assert.strictEqual(row.rows[0].monitoring_enabled, false);
    assert.strictEqual(row.rows[0].consent_state, 'declined');
    assert.ok(row.rows[0].consent_declined_at instanceof Date);
    assert.strictEqual(row.rows[0].detector_version, 'presence-1.0.0');
    assert.ok(row.rows[0].purge_after > new Date(), 'the retention clock is stamped at insert');

    // Ingest is refused while consent is not granted.
    const ingest = await req(baseURL, {
      method: 'POST', path: '/presence/events', leaveToken: joined.json.leaveToken,
      body: {
        roomCode: code, identity,
        events: [{ eventType: 'face_absent', startedAt: new Date().toISOString(), durationMs: 0 }],
      },
    });
    assert.strictEqual(ingest.status, 409);
    assert.strictEqual(ingest.json.code, 'PRESENCE_CONSENT_REQUIRED');

    // The interviewer sees the true state, not an absence of information.
    const timeline = await req(baseURL, {
      method: 'GET', token: h.tokenFor(hostUser),
      path: `/presence/timeline/${code}/${identity}?callerIdentity=${hostIdentity}`,
    });
    assert.strictEqual(timeline.status, 200, JSON.stringify(timeline.json));
    assert.strictEqual(timeline.json.monitoringEnabled, false);
    assert.strictEqual(timeline.json.consentState, 'declined');
    assert.deepStrictEqual(timeline.json.events, []);
    assert.deepStrictEqual(timeline.json.summary, []);

    assert.ok(await waitForAudit('presence_consent_declined', code),
      'a decline is on the audit trail');
    assert.ok(await waitForAudit('presence_monitoring_disabled', code));
  });

  await t.test('a non-moderator cannot read another identity\'s timeline', async () => {
    const hostUser = await h.createUser({ tier: 'hiring' }); track.push(hostUser.id);
    const otherUser = await h.createUser({ tier: 'hiring' }); track.push(otherUser.id);
    const hostIdentity = `host-${nodeCrypto.randomUUID()}`;
    const code = await seedRoom({ hostIdentity, hostTier: 'hiring' });
    await bindModerator(code, hostIdentity, hostUser.id);

    const candidate = `cand-${nodeCrypto.randomUUID()}`;
    const candJoin = await req(baseURL, {
      method: 'POST', path: '/room/join',
      body: { roomCode: code, identity: candidate, displayName: 'Candidate' },
    });
    assert.strictEqual(candJoin.status, 200);

    // The other user joins as a participant and is bound to their own identity.
    const otherIdentity = `peer-${nodeCrypto.randomUUID()}`;
    const otherJoin = await req(baseURL, {
      method: 'POST', path: '/room/join', token: h.tokenFor(otherUser),
      body: { roomCode: code, identity: otherIdentity, displayName: 'Peer' },
    });
    assert.strictEqual(otherJoin.status, 200);

    const ownIdentity = await req(baseURL, {
      method: 'GET', token: h.tokenFor(otherUser),
      path: `/presence/timeline/${code}/${candidate}?callerIdentity=${otherIdentity}`,
    });
    assert.strictEqual(ownIdentity.status, 403, 'a participant is not a moderator');
    assert.strictEqual(ownIdentity.json.code, 'PRESENCE_FORBIDDEN');

    // The load-bearing one: an authenticated participant passing the HOST's
    // (peer-visible) identity is still refused, because the identity→userId
    // binding does not match the authenticated caller.
    const impersonating = await req(baseURL, {
      method: 'GET', token: h.tokenFor(otherUser),
      path: `/presence/timeline/${code}/${candidate}?callerIdentity=${hostIdentity}`,
    });
    assert.strictEqual(impersonating.status, 403,
      'claiming the host identity must not read another candidate\'s events');
    assert.strictEqual(impersonating.json.code, 'PRESENCE_FORBIDDEN');

    // And an unauthenticated read is 401 from the shared auth stack.
    const anonymous = await req(baseURL, {
      method: 'GET',
      path: `/presence/timeline/${code}/${candidate}?callerIdentity=${hostIdentity}`,
    });
    assert.strictEqual(anonymous.status, 401);
  });

  await t.test('an armed hiring room records a batch, and the timeline reports per-type counts', async () => {
    const hostUser = await h.createUser({ tier: 'hiring' }); track.push(hostUser.id);
    const hostIdentity = `host-${nodeCrypto.randomUUID()}`;
    const code = await seedRoom({ hostIdentity, hostTier: 'hiring' });
    await bindModerator(code, hostIdentity, hostUser.id);
    const hostToken = h.tokenFor(hostUser);

    const identity = `cand-${nodeCrypto.randomUUID()}`;
    const joined = await req(baseURL, {
      method: 'POST', path: '/room/join',
      body: { roomCode: code, identity, displayName: 'Candidate' },
    });
    const leaveToken = joined.json.leaveToken;

    const consent = await req(baseURL, {
      method: 'POST', path: '/presence/consent', leaveToken,
      body: { roomCode: code, identity, decision: 'grant' },
    });
    assert.strictEqual(consent.status, 200);
    assert.strictEqual(consent.json.monitoringEnabled, true);
    assert.strictEqual(consent.json.consentState, 'granted');
    assert.strictEqual(consent.json.consentVersion, 'presence-2026-10-31');
    assert.ok(await waitForAudit('presence_consent_granted', code));
    assert.ok(await waitForAudit('presence_monitoring_enabled', code));

    const t0 = Date.now();
    const iso = (offsetMs) => new Date(t0 + offsetMs).toISOString();
    const ingest = await req(baseURL, {
      method: 'POST', path: '/presence/events', leaveToken,
      body: {
        roomCode: code, identity,
        events: [
          { eventType: 'face_absent', startedAt: iso(0), endedAt: iso(12000), durationMs: 12000 },
          { eventType: 'image_quality_insufficient', startedAt: iso(20000), endedAt: iso(36000), durationMs: 16000 },
          { eventType: 'camera_disabled', startedAt: iso(40000), endedAt: iso(40000), durationMs: 0 },
        ],
      },
    });
    assert.strictEqual(ingest.status, 200, JSON.stringify(ingest.json));
    assert.strictEqual(ingest.json.accepted, 3);

    // multiple_faces is gated off for this room and is refused, not stored.
    const gated = await req(baseURL, {
      method: 'POST', path: '/presence/events', leaveToken,
      body: { roomCode: code, identity, events: [{ eventType: 'multiple_faces', startedAt: iso(50000) }] },
    });
    assert.strictEqual(gated.status, 409);
    assert.strictEqual(gated.json.code, 'PRESENCE_EVENT_TYPE_DISABLED');

    // A forbidden field is refused over the wire too, not just in the unit test.
    const forbidden = await req(baseURL, {
      method: 'POST', path: '/presence/events', leaveToken,
      body: {
        roomCode: code, identity,
        events: [{ eventType: 'face_absent', startedAt: iso(60000), score: 0.9 }],
      },
    });
    assert.strictEqual(forbidden.status, 400);
    assert.strictEqual(forbidden.json.code, 'PRESENCE_FORBIDDEN_FIELD');
    assert.strictEqual(forbidden.json.field, 'score');

    const timeline = await req(baseURL, {
      method: 'GET', token: hostToken,
      path: `/presence/timeline/${code}/${identity}?callerIdentity=${hostIdentity}`,
    });
    assert.strictEqual(timeline.status, 200, JSON.stringify(timeline.json));
    assert.strictEqual(timeline.json.monitoringEnabled, true);
    assert.strictEqual(timeline.json.events.length, 3, 'exactly the three accepted events');
    assert.strictEqual(timeline.json.detectorVersion, 'presence-1.0.0');
    assert.strictEqual(timeline.json.multipleFacesEnabled, false);
    assert.ok(timeline.json.sessionDurationMs >= 0);

    const byType = new Map(timeline.json.summary.map((s) => [s.eventType, s]));
    assert.strictEqual(byType.get('face_absent').count, 1);
    assert.strictEqual(byType.get('face_absent').totalDurationMs, 12000);
    assert.strictEqual(byType.get('face_absent').liveSurfaceable, true);
    assert.strictEqual(byType.get('image_quality_insufficient').count, 1);
    assert.strictEqual(byType.get('image_quality_insufficient').totalDurationMs, 16000);
    assert.strictEqual(byType.get('image_quality_insufficient').liveSurfaceable, false,
      'a data-quality fact about the video is never surfaced live as a candidate behaviour');
    assert.strictEqual(byType.get('camera_disabled').count, 1);
    assert.ok(!byType.has('multiple_faces'), 'the gated type never reached the store');

    // THE no-score rule, asserted on the wire. The evaluation surface is
    // per-type counts and durations ONLY: a summary row has exactly four keys,
    // and there is no total, weighting, percentage, rating, risk level or
    // comparison anywhere in the response — not now and not later.
    for (const row of timeline.json.summary) {
      assert.deepStrictEqual(Object.keys(row).sort(),
        ['count', 'eventType', 'liveSurfaceable', 'totalDurationMs'],
        'a summary row carries a per-type count and duration and nothing else');
    }
    assert.ok(!Object.keys(timeline.json).some((k) => /^(total|overall|aggregate|index|score|risk|rating)/i.test(k)),
      'no aggregate key may appear at the top level of the timeline');
    assert.strictEqual(findForbiddenKey(timeline.json), null,
      'no prohibited concept may appear as a key anywhere in the response');

    // Every event carries the operating point it was recorded under, stamped by
    // the server from the session row.
    for (const e of timeline.json.events) {
      assert.strictEqual(e.detectorVersion, 'presence-1.0.0');
      assert.strictEqual(e.source, 'client');
      assert.ok(e.thresholds && typeof e.thresholds === 'object');
      assert.ok(Number.isInteger(e.offsetMs));
    }
    assert.ok(await waitForAudit('presence_timeline_read', code));

    // --- the note rule -----------------------------------------------------
    const eventId = timeline.json.events[0].id;
    const tooShort = await req(baseURL, {
      method: 'POST', token: hostToken,
      path: `/presence/timeline/${code}/${identity}/note`,
      body: { callerIdentity: hostIdentity, eventId, note: 'too short' },
    });
    assert.strictEqual(tooShort.status, 400);
    assert.strictEqual(tooShort.json.code, 'PRESENCE_NOTE_REASON_REQUIRED');

    const whitespaceOnly = await req(baseURL, {
      method: 'POST', token: hostToken,
      path: `/presence/timeline/${code}/${identity}/note`,
      body: { callerIdentity: hostIdentity, eventId, note: '              ' },
    });
    assert.strictEqual(whitespaceOnly.status, 400);
    assert.strictEqual(whitespaceOnly.json.code, 'PRESENCE_NOTE_REASON_REQUIRED');

    const noteText = 'Candidate said they were fetching a charger.';
    const saved = await req(baseURL, {
      method: 'POST', token: hostToken,
      path: `/presence/timeline/${code}/${identity}/note`,
      body: { callerIdentity: hostIdentity, eventId, note: noteText },
    });
    assert.strictEqual(saved.status, 201, JSON.stringify(saved.json));
    assert.ok(saved.json.noteId);

    const stored = await h.db.query(
      'SELECT note_text_enc, note_key_version, author_display_name FROM interview_presence_notes WHERE id = $1',
      [saved.json.noteId]
    );
    assert.strictEqual(stored.rows.length, 1);
    assert.ok(!stored.rows[0].note_text_enc.includes('charger'),
      'the note is stored encrypted, never as plaintext');
    assert.match(stored.rows[0].note_text_enc, /^v\d+:[0-9a-f]+:[0-9a-f]+:[0-9a-f]+$/);
    assert.ok(stored.rows[0].note_key_version >= 1);

    const withNote = await req(baseURL, {
      method: 'GET', token: hostToken,
      path: `/presence/timeline/${code}/${identity}?callerIdentity=${hostIdentity}`,
    });
    const annotated = withNote.json.events.find((e) => e.id === eventId);
    assert.strictEqual(annotated.notes.length, 1);
    assert.strictEqual(annotated.notes[0].text, noteText, 'it round-trips through decryption');
    assert.ok(annotated.notes[0].author.length > 0);

    assert.ok(await waitForAudit('presence_note_added', code));
    const auditedNote = await h.db.query(
      `SELECT metadata FROM audit_events WHERE event_type = 'presence_note_added'
         AND metadata->>'roomCode' = $1 LIMIT 1`, [code]
    );
    assert.ok(!JSON.stringify(auditedNote.rows[0].metadata).includes('charger'),
      'the audit trail records that a note was written, never what it said');

    // --- a note on someone else's event is refused -------------------------
    const foreign = await req(baseURL, {
      method: 'POST', token: hostToken,
      path: `/presence/timeline/${code}/${identity}/note`,
      body: { callerIdentity: hostIdentity, eventId: 999999999, note: 'This event is not in this session.' },
    });
    assert.strictEqual(foreign.status, 404);
    assert.strictEqual(foreign.json.code, 'PRESENCE_SESSION_NOT_FOUND');

    // --- export ------------------------------------------------------------
    const csv = await req(baseURL, {
      method: 'GET', token: hostToken,
      path: `/presence/export/${code}/${identity}?format=csv&callerIdentity=${hostIdentity}`,
    });
    assert.strictEqual(csv.status, 200);
    assert.match(csv.contentType, /text\/csv/);
    const lines = csv.text.trim().split('\r\n');
    assert.strictEqual(lines[0],
      'event_type,started_at,ended_at,duration_ms,offset_ms,detector_version,source,thresholds_json');
    assert.strictEqual(lines.length, 4, 'a header row plus one row per event');
    assert.match(lines[1], /^"face_absent"/);
    assert.ok(await waitForAudit('presence_export', code));

    const json = await req(baseURL, {
      method: 'GET', token: hostToken,
      path: `/presence/export/${code}/${identity}?callerIdentity=${hostIdentity}`,
    });
    assert.strictEqual(json.status, 200);
    assert.strictEqual(json.json.events.length, 3);
  });

  await t.test('ingest before any consent record is 404 PRESENCE_SESSION_NOT_FOUND', async () => {
    const code = await seedRoom({ hostIdentity: 'host-nosession', hostTier: 'hiring' });
    const identity = `cand-${nodeCrypto.randomUUID()}`;
    const joined = await req(baseURL, {
      method: 'POST', path: '/room/join',
      body: { roomCode: code, identity, displayName: 'Candidate' },
    });
    const r = await req(baseURL, {
      method: 'POST', path: '/presence/events', leaveToken: joined.json.leaveToken,
      body: { roomCode: code, identity, events: [] },
    });
    assert.strictEqual(r.status, 404);
    assert.strictEqual(r.json.code, 'PRESENCE_SESSION_NOT_FOUND');
  });

  await t.test('an unarmed room refuses consent with 409 PRESENCE_MONITORING_NOT_ARMED', async () => {
    const code = await seedRoom({ hostIdentity: 'host-unarmed', hostTier: 'hiring', armed: false });
    const identity = `cand-${nodeCrypto.randomUUID()}`;
    const joined = await req(baseURL, {
      method: 'POST', path: '/room/join',
      body: { roomCode: code, identity, displayName: 'Candidate' },
    });
    const r = await req(baseURL, {
      method: 'POST', path: '/presence/consent', leaveToken: joined.json.leaveToken,
      body: { roomCode: code, identity, decision: 'grant' },
    });
    assert.strictEqual(r.status, 409);
    assert.strictEqual(r.json.code, 'PRESENCE_MONITORING_NOT_ARMED');
  });

  await t.test('the rate limiter answers 429 RATE_LIMITED with Retry-After', async () => {
    const code = await seedRoom({ hostIdentity: 'host-rl', hostTier: 'hiring' });
    const identity = `cand-${nodeCrypto.randomUUID()}`;
    const joined = await req(baseURL, {
      method: 'POST', path: '/room/join',
      body: { roomCode: code, identity, displayName: 'Candidate' },
    });
    const leaveToken = joined.json.leaveToken;

    // The consent limiter is 10 per 600 s per (code, identity).
    let limited = null;
    for (let i = 0; i < 12 && limited === null; i++) {
      const r = await fetch(`${baseURL}/presence/consent`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Leave-Token': leaveToken },
        body: JSON.stringify({ roomCode: code, identity, decision: 'decline' }),
      });
      if (r.status === 429) limited = r;
    }
    assert.ok(limited, 'the 11th consent call in the window is limited');
    assert.strictEqual((await limited.json()).code, 'RATE_LIMITED');
    assert.ok(Number(limited.headers.get('retry-after')) > 0,
      'a limited caller is told when to come back');

    await redis.del(`ratelimit:presence-consent:lt:${code}:${identity}`);
  });
});
