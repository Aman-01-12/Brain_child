#!/usr/bin/env node
// ============================================================================
// test-password-reset.js — Password reset flow integration test
//
// Verifies the security properties of the forgot/reset-password flow, with an
// emphasis on the Finding-5 regression: flooding forgot-password must NEVER
// lock the victim out of LOGIN (separate rate-limit namespaces).
//
// Prerequisites:
//   1. Server running:  node index.js   (in another terminal)
//   2. Postgres with migrations applied  (009_password_reset_tokens.sql)
//   3. Redis running    (rate-limit counters)
//
// Usage:
//   node test-password-reset.js
//
// NOTE: HTTP-only. The valid-token redemption path is NOT covered here because
// the raw token is delivered by email and never returned by the API — that path
// needs DB/SMTP introspection and is verified manually. These tests lock the
// parts an attacker can reach without the email: anti-enumeration, invalid-token
// rejection, and the rate-limit isolation between forgot-password and login.
// ============================================================================

const http = require('http');

const PORT = process.env.PORT || 3000;
const BASE = `http://localhost:${PORT}`;

function request(method, path, body, headers = {}) {
  return new Promise((resolve, reject) => {
    const url = new URL(path, BASE);
    const payload = body ? JSON.stringify(body) : null;
    const opts = {
      hostname: url.hostname,
      port: url.port,
      path: url.pathname + url.search,
      method,
      headers: { ...(payload ? { 'Content-Type': 'application/json' } : {}), ...headers },
    };
    const req = http.request(opts, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        const raw = Buffer.concat(chunks).toString('utf8');
        let json; try { json = JSON.parse(raw); } catch { json = null; }
        resolve({ status: res.statusCode, body: json, raw });
      });
    });
    req.on('error', reject);
    if (payload) req.write(payload);
    req.end();
  });
}

let passed = 0, failed = 0;
function check(name, cond, detail) {
  if (cond) { console.log(`  \u2713 ${name}`); passed++; }
  else { console.error(`  \u2717 ${name}${detail ? ` \u2014 ${detail}` : ''}`); failed++; }
}

async function main() {
  const stamp = Date.now();
  const email = `reset-test-${stamp}@example.com`;
  const password = 'TestPass123!';

  console.log('\n\u25B8 Step 1: register a user to log in with later');
  const reg = await request('POST', '/auth/register', {
    email, password, displayName: 'Reset Tester',
  });
  check('register returns 200', reg.status === 200, `got ${reg.status}`);

  console.log('\n\u25B8 Step 2: anti-enumeration \u2014 forgot-password is generic for any email');
  const known = await request('POST', '/auth/forgot-password', { email });
  const unknown = await request('POST', '/auth/forgot-password', { email: `nobody-${stamp}@example.com` });
  check('known email \u2192 200', known.status === 200, `got ${known.status}`);
  check('unknown email \u2192 200', unknown.status === 200, `got ${unknown.status}`);
  check('identical generic body (no enumeration)',
        known.raw === unknown.raw, `"${known.raw}" vs "${unknown.raw}"`);

  console.log('\n\u25B8 Step 3: reset-password rejects an invalid token with 400 (not 500/200)');
  const bad = await request('POST', '/auth/reset-password', {
    token: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', newPassword: password,
  });
  check('invalid token \u2192 400', bad.status === 400, `got ${bad.status}`);

  console.log('\n\u25B8 Step 4: [Finding 5] flooding forgot-password must NOT lock out login');
  // Flood forgot-password past its cap (>10 in the window) for our email.
  let forgotBlocked = false;
  for (let i = 0; i < 13; i++) {
    const r = await request('POST', '/auth/forgot-password', { email });
    if (r.status === 429) forgotBlocked = true;
  }
  check('forgot-password eventually 429s under flood', forgotBlocked,
        'expected a 429 after >10 requests');
  // The victim must STILL be able to log in — login uses a SEPARATE counter.
  const login = await request('POST', '/auth/login', { email, password });
  check('login still works after forgot-password flood (separate namespace)',
        login.status === 200,
        `got ${login.status} \u2014 if 429, the forgot/login counters are shared (regression)`);

  console.log('\n\u25B8 Step 5: reset-password is itself rate-limited (IP-keyed)');
  let resetBlocked = false;
  for (let i = 0; i < 13; i++) {
    const r = await request('POST', '/auth/reset-password', {
      token: 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB', newPassword: password,
    });
    if (r.status === 429) resetBlocked = true;
  }
  check('reset-password eventually 429s under flood', resetBlocked,
        'expected a 429 after >10 requests');

  console.log(`\n${failed === 0 ? '\u2705' : '\u274C'} ${passed} passed, ${failed} failed\n`);
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((err) => {
  console.error('Test run failed:', err.message);
  console.error('Is the server running on', BASE, '? (node index.js)');
  process.exit(1);
});
