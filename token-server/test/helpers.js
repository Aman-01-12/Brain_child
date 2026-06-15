// ============================================================================
// Test helpers — Teams chat backend (node:test integration harness)
//
// Builds a throwaway Express app mounting the REAL teams router behind the REAL
// authenticateToken middleware, seeds users/teams directly in Postgres, and
// issues REAL access tokens via auth.generateAccessToken. This exercises the
// genuine authorization stack (auth + requireTeamMembership + idempotency +
// rate limits) against the live dev DB + Redis.
//
// dotenv MUST load before requiring auth (auth.js exits if JWT_SECRET is unset).
// ============================================================================

require('dotenv').config();

const express = require('express');
const crypto = require('crypto');
const db = require('./../db');
const auth = require('./../auth');
const teamsRouter = require('./../teams');

function buildTestApp() {
  const app = express();
  app.use(express.json());
  app.use(auth.authenticateToken);          // sets req.user from Bearer token
  app.use('/teams', teamsRouter);
  // Safety net so an unexpected throw becomes a 500 rather than crashing the run.
  app.use((err, _req, res, _next) => {
    res.status(err.status || 500).json({ error: err.message });
  });
  return app;
}

async function startServer() {
  const app = buildTestApp();
  const server = await new Promise((resolve) => {
    const s = app.listen(0, '127.0.0.1', () => resolve(s));
  });
  return { server, baseURL: `http://127.0.0.1:${server.address().port}` };
}

async function createUser({ tier = 'free' } = {}) {
  const email = `teamtest-${crypto.randomUUID()}@test.invalid`;
  const res = await db.query(
    `INSERT INTO users (email, display_name, password_hash, tier)
     VALUES ($1, $2, $3, $4)
     RETURNING id, email, display_name, tier`,
    [email, 'Test User', 'x', tier]
  );
  return res.rows[0];
}

function tokenFor(user) {
  return auth.generateAccessToken(user, crypto.randomUUID());
}

async function createTeam(ownerUser) {
  const t = await db.query(
    `INSERT INTO teams (name, owner_user_id) VALUES ($1, $2) RETURNING id`,
    ['Test Team', ownerUser.id]
  );
  const teamId = t.rows[0].id;
  await db.query(
    `INSERT INTO team_members (team_id, user_id, email, role, status, joined_at)
     VALUES ($1, $2, $3, 'owner', 'active', NOW())`,
    [teamId, ownerUser.id, ownerUser.email]
  );
  return teamId;
}

async function addMember(teamId, user, role = 'member') {
  await db.query(
    `INSERT INTO team_members (team_id, user_id, email, role, status, joined_at)
     VALUES ($1, $2, $3, $4, 'active', NOW())`,
    [teamId, user.id, user.email, role]
  );
}

async function memberMid(teamId, userId) {
  const r = await db.query(
    `SELECT id FROM team_members WHERE team_id = $1 AND user_id = $2`,
    [teamId, userId]
  );
  return r.rows[0]?.id;
}

async function insertFile(teamId, uploaderId) {
  const r = await db.query(
    `INSERT INTO team_files (team_id, uploader_user_id, s3_key, original_name, mime_type, size_bytes, is_image)
     VALUES ($1, $2, $3, 'pic.png', 'image/png', 123, true)
     RETURNING id`,
    [teamId, uploaderId, `team-files/${teamId}/${crypto.randomUUID()}`]
  );
  return r.rows[0].id;
}

// A fully isolated {owner, token, teamId} so rate-limit tests don't share a
// per-(team,user) budget with the functional tests.
async function isolatedTeam(track) {
  const owner = await createUser();
  track.push(owner.id);
  const teamId = await createTeam(owner);
  return { owner, token: tokenFor(owner), teamId };
}

async function cleanupUsers(ids) {
  if (ids.length) {
    // Deleting owners cascades teams -> team_members/messages/files.
    await db.query(`DELETE FROM users WHERE id = ANY($1)`, [ids]);
  }
}

// Minimal fetch wrapper. Pass idemKey to control idempotency (H10); otherwise a
// fresh UUID is used so unrelated writes never dedup against each other.
async function api(baseURL, { method = 'GET', path, token, body, idemKey } = {}) {
  const headers = {};
  if (token) headers['Authorization'] = `Bearer ${token}`;
  const opts = { method, headers };
  if (body !== undefined) {
    headers['Content-Type'] = 'application/json';
    headers['X-Idempotency-Key'] = idemKey || crypto.randomUUID();
    opts.body = JSON.stringify(body);
  }
  const res = await fetch(`${baseURL}${path}`, opts);
  let json = null;
  try { json = await res.json(); } catch { /* non-JSON / empty */ }
  return { status: res.status, json };
}

module.exports = {
  startServer, createUser, tokenFor, createTeam, addMember, memberMid,
  insertFile, isolatedTeam, cleanupUsers, api, db,
};
