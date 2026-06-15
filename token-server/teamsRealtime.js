// ============================================================================
// Team Realtime — Socket.IO fan-out seam for team chat
// Phase 11.5 / Task 3 (see docs/superpowers/specs/2026-06-11-teams-chat-design.md)
//
// The REST layer is the source of truth: every team write persists to Postgres
// first, then calls emitTeamEvent() to fan the result out to online members over
// the dedicated `/teams` Socket.IO namespace (rooms named `team:<teamId>`).
//
// This module owns the namespace reference so the teams router (teams.js) can
// emit without importing the io instance. The namespace itself — JWT handshake
// auth (C2), membership-gated join (C1), and per-user socket eviction (C3) — is
// attached in index.js after `io` is created (Phase 2). Until then emitTeamEvent
// is a safe no-op: the REST endpoints work standalone (history is fetched over
// REST), and a missed fan-out never loses a message because the client
// reconciles from persisted history on open/reconnect.
// ============================================================================

const db = require('./db');
const auth = require('./auth');

// Set by attachTeamsNamespace(io). Null until then.
let teamsNsp = null;

// Per-user live socket registry on the /teams namespace: userId -> Set<socketId>.
// Drives instant eviction on membership loss (C3) and the per-user connection
// cap (H8). Entries are removed on disconnect so the map cannot grow unbounded.
const userSockets = new Map();

const MAX_SOCKETS_PER_USER = 8; // per-user connection cap (H8)
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function setTeamsNamespace(nsp) {
  teamsNsp = nsp;
}

// Fan a persisted team event out to all online members of a team.
// teamId: UUID string. event: e.g. 'team:message'. payload: JSON-serializable.
// Best-effort: guarded no-op until the namespace is attached, and never throws
// into the REST request path (a delivery hint failing must not fail the write).
function emitTeamEvent(teamId, event, payload) {
  if (!teamsNsp || !teamId) return;
  try {
    teamsNsp.to(`team:${teamId}`).emit(event, payload);
  } catch (err) {
    console.error('[teams-realtime] emit error:', err.message);
  }
}

// authenticateTeamHandshake(handshakeAuth) -> { userId, email, displayName }
// Verifies the access JWT presented in the Socket.IO handshake `auth` payload
// (C2). The token travels in `auth`, never the query string (H6 — avoids
// access-log leakage). Throws on missing/invalid/expired token (fail-closed).
// Exported so the guard logic can be unit-tested without a live socket.
function authenticateTeamHandshake(handshakeAuth) {
  const token = handshakeAuth && typeof handshakeAuth.token === 'string' ? handshakeAuth.token : '';
  if (!token) {
    const err = new Error('unauthorized'); err.code = 'NO_TOKEN'; throw err;
  }
  const decoded = auth.verifyAccessToken(token); // throws on invalid/expired
  if (!decoded || !decoded.userId) {
    const err = new Error('unauthorized'); err.code = 'NO_SUBJECT'; throw err;
  }
  return { userId: decoded.userId, email: decoded.email, displayName: decoded.displayName };
}

// isActiveTeamMember(teamId, userId) -> boolean. Authorization at the data layer
// (C1) — the same membership predicate the REST guard enforces, used to gate
// socket room joins so a client-supplied teamId is never trusted on its own.
async function isActiveTeamMember(teamId, userId) {
  const result = await db.query(
    `SELECT 1 FROM team_members
     WHERE team_id = $1 AND user_id = $2 AND status = 'active'`,
    [teamId, userId]
  );
  return result.rows.length > 0;
}

function registerSocket(userId, socket) {
  let set = userSockets.get(userId);
  if (!set) { set = new Set(); userSockets.set(userId, set); }
  set.add(socket.id);
}

function unregisterSocket(userId, socket) {
  const set = userSockets.get(userId);
  if (!set) return;
  set.delete(socket.id);
  if (set.size === 0) userSockets.delete(userId);
}

// evictUserFromTeam(teamId, userId) — force a user out of a team room the moment
// they lose membership (C3: removal). Each of their live sockets leaves the room
// and is told membership was revoked, so a still-valid 15-min access JWT cannot
// keep receiving the team's messages. Best-effort + idempotent.
function evictUserFromTeam(teamId, userId) {
  if (!teamsNsp || !teamId || !userId) return;
  const set = userSockets.get(userId);
  if (!set || set.size === 0) return;
  for (const socketId of set) {
    const s = teamsNsp.sockets.get(socketId);
    if (!s) continue;
    try {
      s.leave(`team:${teamId}`);
      s.emit('team:membership-revoked', { teamId });
    } catch (err) {
      console.error('[teams-realtime] evict error:', err.message);
    }
  }
}

// evictTeam(teamId) — defense-in-depth eviction for team deletion (C3): tell
// everyone in the room membership was revoked, then force them all to leave.
function evictTeam(teamId) {
  if (!teamsNsp || !teamId) return;
  try {
    teamsNsp.to(`team:${teamId}`).emit('team:membership-revoked', { teamId });
    teamsNsp.in(`team:${teamId}`).socketsLeave(`team:${teamId}`);
  } catch (err) {
    console.error('[teams-realtime] evictTeam error:', err.message);
  }
}

// attachTeamsNamespace(io) — wire the dedicated /teams namespace. Fully isolated
// from the in-call default namespace (`/`): this guard and these handlers never
// touch in-call moderation. Call once, immediately after `io` is created.
function attachTeamsNamespace(io) {
  const nsp = io.of('/teams');

  // C2 — fail-closed JWT handshake guard. A connection without a valid access
  // token is rejected before it can join anything.
  nsp.use((socket, next) => {
    try {
      const identity = authenticateTeamHandshake(socket.handshake.auth || {});
      socket.data.userId = identity.userId;
      socket.data.email = identity.email;
      socket.data.displayName = identity.displayName;
      // OWASP WebSocket logging: record auth success with identity + transport,
      // never the token. HTTP logs miss all socket traffic, so this is the only
      // record of who connected.
      console.log(`[teams-socket] handshake OK user=${identity.userId} transport=${socket.conn.transport.name}`);
      return next();
    } catch (err) {
      console.warn(`[teams-socket] handshake REJECTED (${err.code || 'invalid'}) ip=${socket.handshake.address}`);
      return next(new Error('unauthorized'));
    }
  });

  nsp.on('connection', (socket) => {
    const userId = socket.data.userId;

    // H8 — per-user connection cap (fail-closed on excess).
    const existing = userSockets.get(userId);
    if (existing && existing.size >= MAX_SOCKETS_PER_USER) {
      socket.emit('error:too-many-connections');
      socket.disconnect(true);
      return;
    }
    registerSocket(userId, socket);
    console.log(`[teams-socket] connected user=${userId} socket=${socket.id}`);

    // team:join { teamId } — membership re-checked against the AUTHENTICATED
    // user (C1) before joining. Read-only: this never mutates state.
    socket.on('team:join', async (payload) => {
      const teamId = payload && typeof payload.teamId === 'string' ? payload.teamId : '';
      if (!UUID_RE.test(teamId)) return;                 // H7 — bound inbound input
      try {
        if (await isActiveTeamMember(teamId, userId)) {
          socket.join(`team:${teamId}`);
          console.log(`[teams-socket] join OK user=${userId} team=${teamId}`);
        } else {
          console.warn(`[teams-socket] join DENIED (not a member) user=${userId} team=${teamId}`);
        }
      } catch (err) {
        console.error('[teams-realtime] join check error:', err.message);
      }
    });

    // team:leave { teamId } — leave the room.
    socket.on('team:leave', (payload) => {
      const teamId = payload && typeof payload.teamId === 'string' ? payload.teamId : '';
      if (!UUID_RE.test(teamId)) return;
      socket.leave(`team:${teamId}`);
    });

    socket.on('disconnect', (reason) => {
      unregisterSocket(userId, socket); // cleanup — no socket-registry leak (2C)
      console.log(`[teams-socket] disconnected user=${userId} socket=${socket.id} reason=${reason}`);
    });
  });

  setTeamsNamespace(nsp);
  return nsp;
}

module.exports = {
  setTeamsNamespace,
  emitTeamEvent,
  attachTeamsNamespace,
  evictUserFromTeam,
  evictTeam,
  // exported for unit tests (no live socket required)
  authenticateTeamHandshake,
  isActiveTeamMember,
  _userSockets: userSockets,
};
