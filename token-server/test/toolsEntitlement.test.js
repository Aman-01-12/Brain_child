// ============================================================================
// Server-signed tools entitlement — integration tests (node:test harness)
//
// Sibling of interviewTierGate.test.js. Where that suite verifies the 403 gate
// on CREATING/SCHEDULING an interview, THIS suite verifies the OTHER half of the
// entitlement story (Task 8 of the collaborative-code-editor spec):
//
//   The server stamps a SIGNED, host-tier-derived `tools` boolean into the
//   LiveKit JWT metadata at /room/create, /room/join, and scheduling's token
//   builder — so a patched client cannot forge access (R9.1), and BOTH the
//   interviewer AND the candidate of a hiring host's room are entitled
//   regardless of the candidate's own tier (R7.2, R7.3).
//
// The `tools` flag is keyed on the room's snapshotted `hostTier` via the
// `tiers.js` SSOT (true exactly when hostTier >= hiring), never on the joiner's
// tier. We decode the LiveKit JWT payload in-test and inspect `metadata.tools`.
//
// /room/join is exercised END-TO-END against the real handler (Redis-seeded
// room, no LiveKit network needed on the join token path). /room/create's happy
// path requires a reachable LiveKit server (its 403 paths are covered by
// interviewTierGate.test.js), so its stamping is verified through the exported
// `createToken` + `toolsEntitlement` builders that the handler itself calls.
// ============================================================================

require('dotenv').config();

const { test, after } = require('node:test');
const assert = require('node:assert');
const crypto = require('crypto');

const redis = require('./../redis');
const tiers = require('./../tiers');
const { app: mainApp, createToken, toolsEntitlement } = require('./../index');
const scheduling = require('./../scheduling');

// --- helpers ---------------------------------------------------------------

// Decode a LiveKit JWT's metadata claim WITHOUT verifying the signature (we are
// inspecting the server-stamped payload, not authenticating it). LiveKit stores
// the metadata as a JSON string in the `metadata` claim.
function metadataFromJwt(jwt) {
  const parts = String(jwt).split('.');
  assert.equal(parts.length, 3, 'expected a three-segment JWT');
  const payload = JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8'));
  if (payload.metadata == null) return {};
  return typeof payload.metadata === 'string' ? JSON.parse(payload.metadata) : payload.metadata;
}

async function listen(app) {
  const server = await new Promise((resolve) => {
    const s = app.listen(0, '127.0.0.1', () => resolve(s));
  });
  return { server, baseURL: `http://127.0.0.1:${server.address().port}` };
}

async function postJSON(baseURL, path, body) {
  const res = await fetch(`${baseURL}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  let json = null;
  try { json = await res.json(); } catch { /* non-JSON */ }
  return { status: res.status, json };
}

// Seed a room hash directly in Redis (the same shape /room/create writes), so we
// can drive the REAL /room/join handler without standing up LiveKit. We set
// joinBeforeHost so a guest joiner is admitted without the host being present,
// and leave lobby/password off so the join returns a token immediately.
const seededCodes = [];
async function seedRoom({ code, hostTier, roomType }) {
  seededCodes.push(code);
  await redis.hset(`room:${code}`, {
    roomName: `inter-${code}`,
    createdAt: Date.now().toString(),
    hostIdentity: 'seed-host',
    roomType,
    hostTier,
    joinBeforeHost: 'true',
    lobbyEnabled: 'false',
    passwordHash: '',
  });
  await redis.expire(`room:${code}`, 300);
  return code;
}

function freshCode(prefix) {
  return `${prefix}${crypto.randomBytes(3).toString('hex').toUpperCase()}`;
}

after(async () => {
  // Remove every key under the rooms we touched (the join handler also writes
  // participants/roles/names/leavetoken keys under room:CODE:*).
  for (const code of seededCodes) {
    try {
      const keys = await redis.keys(`room:${code}*`);
      if (keys.length) await redis.del(keys);
    } catch (_) { /* best-effort */ }
  }
  redis.disconnect();
});

// --- SSOT sanity -----------------------------------------------------------

test('toolsEntitlement mirrors the HOST_INTERVIEW cap (hiring-only) via tiers SSOT', () => {
  assert.equal(toolsEntitlement('hiring'), true,  'hiring host ⇒ tools entitled');
  assert.equal(toolsEntitlement('pro'),    false, 'pro host ⇒ no tools');
  assert.equal(toolsEntitlement('free'),   false, 'free host ⇒ no tools');
  assert.equal(toolsEntitlement(undefined), false, 'unknown tier fails closed');
  // Bound to the SSOT, not a literal — must equal isFeatureAllowed for HOST_INTERVIEW.
  for (const t of ['free', 'pro', 'hiring', 'bogus']) {
    assert.equal(
      toolsEntitlement(t),
      tiers.isFeatureAllowed(t, tiers.FEATURES.HOST_INTERVIEW),
      `toolsEntitlement('${t}') must equal the SSOT HOST_INTERVIEW check`
    );
  }
});

// --- /room/create stamping (via the builders the handler calls) ------------
//
// The /room/create handler builds `metadata = { role, tools: toolsEntitlement(hostTier) }`
// and signs it with createToken(). We reproduce exactly that and decode the JWT.

test('/room/create token metadata carries tools=true only for a hiring host', async () => {
  for (const hostTier of ['hiring', 'pro', 'free']) {
    const role = hostTier === 'hiring' ? 'interviewer' : 'host';
    const metadata = { role, tools: toolsEntitlement(hostTier) };
    const jwt = await createToken('host-1', 'Host', `inter-${freshCode('CR')}`, true, metadata);
    const meta = metadataFromJwt(jwt);
    assert.equal(meta.role, role);
    assert.equal(meta.tools, hostTier === 'hiring', `hostTier=${hostTier} ⇒ tools=${hostTier === 'hiring'}`);
  }
});

// --- /room/join end-to-end (real handler, Redis-seeded room) ---------------
//
// This is the load-bearing R7.2 case: a GUEST joiner (unauthenticated — i.e. no
// tier of their own) of a HIRING host's room must still receive tools=true,
// because the entitlement is derived from the room's hostTier, not the joiner's.

test('POST /room/join — token tools entitlement is derived from the room hostTier, not the joiner', async (t) => {
  const { server, baseURL } = await listen(mainApp);
  t.after(() => server.close());

  await t.test('hiring-host room ⇒ guest joiner token carries tools:true (R7.2)', async () => {
    const code = await seedRoom({ code: freshCode('HIRE'), hostTier: 'hiring', roomType: 'interview' });
    const r = await postJSON(baseURL, '/room/join', {
      roomCode: code, identity: 'candidate-1', displayName: 'Candidate',
    });
    assert.equal(r.status, 200, `join should succeed: ${JSON.stringify(r.json)}`);
    const meta = metadataFromJwt(r.json.token);
    assert.equal(meta.role, 'interviewee');
    assert.equal(meta.tools, true);
  });

  await t.test('pro-host room ⇒ joiner token carries tools:false', async () => {
    const code = await seedRoom({ code: freshCode('PRO'), hostTier: 'pro', roomType: 'call' });
    const r = await postJSON(baseURL, '/room/join', {
      roomCode: code, identity: 'joiner-2', displayName: 'Joiner',
    });
    assert.equal(r.status, 200, `join should succeed: ${JSON.stringify(r.json)}`);
    assert.equal(metadataFromJwt(r.json.token).tools, false);
  });

  await t.test('free-host room ⇒ joiner token carries tools:false', async () => {
    const code = await seedRoom({ code: freshCode('FREE'), hostTier: 'free', roomType: 'call' });
    const r = await postJSON(baseURL, '/room/join', {
      roomCode: code, identity: 'joiner-3', displayName: 'Joiner',
    });
    assert.equal(r.status, 200, `join should succeed: ${JSON.stringify(r.json)}`);
    assert.equal(metadataFromJwt(r.json.token).tools, false);
  });
});

// --- scheduling.js _createLiveKitToken stamping ----------------------------
//
// Scheduled-meeting tokens are minted by scheduling.js (not index.createToken);
// verify the same hostTier-derived entitlement is stamped there too.

test('scheduling _createLiveKitToken stamps the hostTier-derived tools entitlement', async () => {
  const toolsFor = (hostTier) => tiers.isFeatureAllowed(hostTier, tiers.FEATURES.HOST_INTERVIEW);

  const hiringJwt = await scheduling._createLiveKitToken(
    'cand', 'Cand', 'inter-SCHED1', false, 'interviewee', toolsFor('hiring'));
  assert.equal(metadataFromJwt(hiringJwt).tools, true);

  const proJwt = await scheduling._createLiveKitToken(
    'joiner', 'Joiner', 'inter-SCHED2', false, 'participant', toolsFor('pro'));
  assert.equal(metadataFromJwt(proJwt).tools, false);
});
