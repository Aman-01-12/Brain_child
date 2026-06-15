// Unit tests — C2/H6: /teams Socket.IO handshake authentication.
// authenticateTeamHandshake is the fail-closed JWT guard for the team namespace.
// Pure (no live socket); dotenv loads before auth so JWT_SECRET is present.

require('dotenv').config();

const { test, describe } = require('node:test');
const assert = require('node:assert');
const crypto = require('crypto');
const jwt = require('jsonwebtoken');
const auth = require('./../auth');
const { authenticateTeamHandshake } = require('./../teamsRealtime');

// teamsRealtime transitively opens the pg pool; close it so this process exits.
require('node:test').after(async () => {
  try { await require('./../db').pool.end(); } catch { /* noop */ }
  try { require('./../redis').disconnect(); } catch { /* noop */ }
});

describe('C2/H6: /teams socket handshake auth', () => {
  test('rejects a handshake with no token (fail-closed)', () => {
    assert.throws(() => authenticateTeamHandshake({}));
    assert.throws(() => authenticateTeamHandshake({ token: '' }));
    assert.throws(() => authenticateTeamHandshake(null));
  });

  test('rejects a structurally invalid token', () => {
    assert.throws(() => authenticateTeamHandshake({ token: 'not-a-jwt' }));
  });

  test('rejects an expired access token', () => {
    const expired = jwt.sign(
      { userId: 'u1', email: 'a@b.c', fam: 'f' },
      process.env.JWT_SECRET,
      { algorithm: 'HS256', issuer: 'inter-token-server', audience: 'inter-macos-client', expiresIn: -10 }
    );
    assert.throws(() => authenticateTeamHandshake({ token: expired }));
  });

  test('rejects a token signed with the wrong secret', () => {
    const forged = jwt.sign(
      { userId: 'u1' },
      'wrong-secret-wrong-secret-wrong-secret-32b',
      { algorithm: 'HS256', issuer: 'inter-token-server', audience: 'inter-macos-client', expiresIn: '15m' }
    );
    assert.throws(() => authenticateTeamHandshake({ token: forged }));
  });

  test('rejects a token with the wrong audience', () => {
    const wrongAud = jwt.sign(
      { userId: 'u1' },
      process.env.JWT_SECRET,
      { algorithm: 'HS256', issuer: 'inter-token-server', audience: 'some-other-app', expiresIn: '15m' }
    );
    assert.throws(() => authenticateTeamHandshake({ token: wrongAud }));
  });

  test('accepts a valid access token and binds the userId', () => {
    const user = { id: 'user-123', email: 'a@b.c', display_name: 'A', tier: 'free' };
    const token = auth.generateAccessToken(user, crypto.randomUUID());
    const identity = authenticateTeamHandshake({ token });
    assert.strictEqual(identity.userId, 'user-123');
    assert.strictEqual(identity.email, 'a@b.c');
  });
});
