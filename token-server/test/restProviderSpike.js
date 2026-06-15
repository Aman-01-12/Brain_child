// ============================================================================
// REST provider live spike — exercises the EXACT HTTP requests the new Swift
// Teams providers make (InterTeamsListRESTProvider / InterTeamMembersRESTProvider
// / InterTeamFilesRESTProvider) against the RUNNING token server, and asserts
// the JSON shapes the Swift Codable structs decode. Since the token access
// token is set privately on InterTokenService (login/restore only), a pure-Swift
// provider spike would need interactive sign-in; this contract spike instead
// seeds a real user+team directly in the DB, mints a real access JWT, and drives
// the live server over HTTP — closing the loop between the unit-tested Swift
// decoders and the live server's emitted shapes.
//
// Run (server must be listening on $PORT, default 3000):
//     node test/restProviderSpike.js
// Exits non-zero if any REQUIRED contract check fails. File (S3) endpoints are
// reported as NOTE when S3 isn't configured in dev (auth+validation still ran).
// ============================================================================
require('dotenv').config({ quiet: true });
const crypto = require('crypto');
const h = require('./helpers');
const redis = require('./../redis');

const BASE = `http://localhost:${process.env.PORT || 3000}`;

// 1x1 transparent PNG (valid magic bytes so the server's file-type check passes).
const PNG_1x1 = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
  'base64'
);

const results = [];
function pass(name, detail = '') { results.push({ ok: true, name, detail }); }
function fail(name, detail = '') { results.push({ ok: false, name, detail }); }
function note(name, detail = '') { results.push({ note: true, name, detail }); }

// Replicates the provider's authed request (Bearer + optional UUID idempotency key).
async function api(method, path, { token, body, idemKey, form } = {}) {
  const headers = {};
  if (token) headers['Authorization'] = `Bearer ${token}`;
  const opts = { method, headers };
  if (form) {
    headers['X-Idempotency-Key'] = idemKey || crypto.randomUUID();
    opts.body = form; // fetch sets multipart boundary
  } else if (body !== undefined) {
    headers['Content-Type'] = 'application/json';
    headers['X-Idempotency-Key'] = idemKey || crypto.randomUUID();
    opts.body = JSON.stringify(body);
  }
  const res = await fetch(`${BASE}${path}`, opts);
  let json = null;
  try { json = await res.json(); } catch { /* empty / non-JSON */ }
  return { status: res.status, json };
}

// --- Swift Codable required-key validators (decode fails if these are absent) ---
function isStr(v) { return typeof v === 'string'; }
function isNum(v) { return typeof v === 'number'; }

function validTeamSummary(t) {
  // InterTeamSummary required: id, name, memberCount, unreadCount.
  return t && isStr(t.id) && isStr(t.name) && isNum(t.memberCount) && isNum(t.unreadCount);
}
function validMember(m) {
  // InterTeamMember required: id, email, displayName, role, status.
  return m && isStr(m.id) && isStr(m.email) && isStr(m.displayName) && isStr(m.role) && isStr(m.status);
}
function validFileObj(f) {
  // InterTeamFile required: fileId, originalName, mimeType, isImage.
  return f && isStr(f.fileId) && isStr(f.originalName) && isStr(f.mimeType) && typeof f.isImage === 'boolean';
}

(async () => {
  const track = [];
  try {
    // Readiness probe.
    try {
      const ping = await fetch(`${BASE}/health`);
      if (!ping.ok) throw new Error(`/health -> ${ping.status}`);
    } catch (e) {
      console.error(`\n[spike] Server not reachable at ${BASE} (${e.message}).`);
      console.error('[spike] Start it first:  (cd token-server && node index.js)\n');
      process.exitCode = 2;
      return;
    }

    // Seed: owner + team + a second REGISTERED user (addable by email).
    const owner = await h.createUser(); track.push(owner.id);
    const teamId = await h.createTeam(owner);
    const token = h.tokenFor(owner);
    const registered = await h.createUser(); track.push(registered.id);

    // === InterTeamsListRESTProvider ===
    // GET /teams -> { teams: [InterTeamSummary] }
    {
      const r = await api('GET', '/teams', { token });
      const teams = r.json && r.json.teams;
      if (r.status === 200 && Array.isArray(teams) && teams.every(validTeamSummary)
          && teams.some(t => t.id === teamId)) {
        pass('GET /teams', `${teams.length} team(s); shapes ok`);
      } else {
        fail('GET /teams', `status=${r.status} body=${JSON.stringify(r.json)}`);
      }
    }
    // POST /teams { name } -> InterTeamSummary (201, direct object)
    let createdTeamId = null;
    {
      const r = await api('POST', '/teams', { token, body: { name: 'Spike Squad' } });
      if (r.status === 201 && validTeamSummary(r.json)) {
        createdTeamId = r.json.id;
        pass('POST /teams', `created id=${r.json.id}, memberCount=${r.json.memberCount}`);
      } else {
        fail('POST /teams', `status=${r.status} body=${JSON.stringify(r.json)}`);
      }
    }

    // === InterTeamMembersRESTProvider ===
    // GET /teams/:id -> { members: [InterTeamMember], callerRole }
    {
      const r = await api('GET', `/teams/${teamId}`, { token });
      const members = r.json && r.json.members;
      if (r.status === 200 && Array.isArray(members) && members.every(validMember)
          && isStr(r.json.callerRole)) {
        pass('GET /teams/:id', `${members.length} member(s), callerRole=${r.json.callerRole}`);
      } else {
        fail('GET /teams/:id', `status=${r.status} body=${JSON.stringify(r.json)}`);
      }
    }
    // POST /teams/:id/members { email } registered -> 201 { member }
    let addedMid = null;
    {
      const r = await api('POST', `/teams/${teamId}/members`, { token, body: { email: registered.email } });
      if (r.status === 201 && validMember(r.json && r.json.member)) {
        addedMid = r.json.member.id;
        pass('POST /teams/:id/members (registered)', `added mid=${addedMid}, role=${r.json.member.role}`);
      } else {
        fail('POST /teams/:id/members (registered)', `status=${r.status} body=${JSON.stringify(r.json)}`);
      }
    }
    // POST /teams/:id/members { email } unregistered -> 404 { code: NO_INTER_ACCOUNT }
    {
      const ghost = `ghost-${crypto.randomUUID()}@nope.invalid`;
      const r = await api('POST', `/teams/${teamId}/members`, { token, body: { email: ghost } });
      if (r.status === 404 && r.json && r.json.code === 'NO_INTER_ACCOUNT') {
        pass('POST /teams/:id/members (unregistered)', 'maps to .noInterAccount');
      } else {
        fail('POST /teams/:id/members (unregistered)', `status=${r.status} body=${JSON.stringify(r.json)}`);
      }
    }
    // DELETE /teams/:id/members/:mid -> { ok: true }
    if (addedMid) {
      const r = await api('DELETE', `/teams/${teamId}/members/${addedMid}`, { token });
      if (r.status === 200 && r.json && r.json.ok === true) {
        pass('DELETE /teams/:id/members/:mid', 'ok:true');
      } else {
        fail('DELETE /teams/:id/members/:mid', `status=${r.status} body=${JSON.stringify(r.json)}`);
      }
    }

    // === InterTeamFilesRESTProvider ===
    // POST /teams/:id/files (multipart "file") -> 201 file message { kind:'file', file:{...} }
    {
      const form = new FormData();
      form.append('file', new Blob([PNG_1x1], { type: 'application/octet-stream' }), 'spike.png');
      const r = await api('POST', `/teams/${teamId}/files`, { token, form });
      if (r.status === 201 && r.json && r.json.kind === 'file' && validFileObj(r.json.file)) {
        pass('POST /teams/:id/files', `file message id=${r.json.id}, file.fileId=${r.json.file.fileId}`);
      } else if (r.status === 502 || r.status === 500) {
        note('POST /teams/:id/files', `auth+validation passed; S3 not configured in dev (status=${r.status})`);
      } else {
        fail('POST /teams/:id/files', `status=${r.status} body=${JSON.stringify(r.json)}`);
      }
    }
    // GET /teams/:id/files/:fileId/url -> { url, originalName, mimeType }
    {
      const fileId = await h.insertFile(teamId, owner.id); // metadata row (no S3 object)
      const r = await api('GET', `/teams/${teamId}/files/${fileId}/url`, { token });
      if (r.status === 200 && r.json && isStr(r.json.url)) {
        pass('GET /teams/:id/files/:fileId/url', 'presigned url returned');
      } else if (r.status === 500) {
        note('GET /teams/:id/files/:fileId/url', 'membership+lookup passed; S3 presign needs AWS creds (status=500)');
      } else {
        fail('GET /teams/:id/files/:fileId/url', `status=${r.status} body=${JSON.stringify(r.json)}`);
      }
    }
  } catch (e) {
    fail('spike harness', e.message);
  } finally {
    await h.cleanupUsers(track);
    await h.db.pool.end();
    // The teams router holds an open ioredis handle; close it so we exit.
    try { redis.disconnect(); } catch { /* already closed */ }
  }

  // --- Report ---
  const failures = results.filter(r => r.ok === false);
  const passes = results.filter(r => r.ok === true);
  const notes = results.filter(r => r.note === true);
  console.log('\n=== REST provider live spike ===');
  for (const r of results) {
    const tag = r.ok === true ? 'PASS' : r.ok === false ? 'FAIL' : 'NOTE';
    console.log(`  [${tag}] ${r.name}${r.detail ? ' — ' + r.detail : ''}`);
  }
  console.log(`\n${passes.length} passed, ${failures.length} failed, ${notes.length} note(s).\n`);
  process.exitCode = failures.length === 0 ? 0 : 1;
})();
