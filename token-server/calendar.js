// ============================================================================
// Calendar Sync Module — Inter Token Server
// Phase 11.2.4 (Google) + 11.2.5 (Outlook)
//
// Provides Express Router for:
//   POST /calendar/google/connect    — Start Google OAuth flow
//   GET  /calendar/google/callback   — Google OAuth callback
//   POST /calendar/google/disconnect — Remove Google token
//   POST /calendar/google/sync/:id   — Sync meeting to Google Calendar
//   POST /calendar/outlook/connect   — Start Outlook OAuth flow
//   GET  /calendar/outlook/callback  — Outlook OAuth callback
//   POST /calendar/outlook/disconnect— Remove Outlook token
//   POST /calendar/outlook/sync/:id  — Sync meeting to Outlook Calendar
//   GET  /calendar/status            — Connection status for both providers
//
// Design:
//   - OAuth refresh tokens stored encrypted (AES-256-GCM via crypto.js)
//   - Server-side token exchange only (no client-side secrets)
//   - Refresh tokens auto-rotate on use (for providers that rotate)
// ============================================================================

const express = require('express');
const router = express.Router();
const crypto = require('crypto');
const https = require('https');
const db = require('./db');
const auth = require('./auth');
const tokenCrypto = require('./crypto');

// ---------------------------------------------------------------------------
// Environment config
// ---------------------------------------------------------------------------

const GOOGLE_CLIENT_ID     = process.env.GOOGLE_CALENDAR_CLIENT_ID || '';
const GOOGLE_CLIENT_SECRET = process.env.GOOGLE_CALENDAR_CLIENT_SECRET || '';
const GOOGLE_REDIRECT_URI  = process.env.GOOGLE_CALENDAR_REDIRECT_URI || 'http://localhost:3000/calendar/google/callback';

const OUTLOOK_CLIENT_ID     = process.env.OUTLOOK_CALENDAR_CLIENT_ID || '';
const OUTLOOK_CLIENT_SECRET = process.env.OUTLOOK_CALENDAR_CLIENT_SECRET || '';
const OUTLOOK_REDIRECT_URI  = process.env.OUTLOOK_CALENDAR_REDIRECT_URI || 'http://localhost:3000/calendar/outlook/callback';
const OUTLOOK_TENANT        = process.env.OUTLOOK_TENANT || 'common';

// CSRF state tokens — stored in Redis if available, in-memory fallback
const pendingStates = new Map();
const STATE_TTL_MS = 10 * 60 * 1000; // 10 minutes

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function httpsRequest(url, options, body) {
  return new Promise((resolve, reject) => {
    const urlObj = new URL(url);
    const reqOptions = {
      hostname: urlObj.hostname,
      path: urlObj.pathname + urlObj.search,
      method: options.method || 'GET',
      headers: options.headers || {},
    };

    const req = https.request(reqOptions, (res) => {
      let data = '';
      res.on('data', (chunk) => { data += chunk; });
      res.on('end', () => {
        try {
          resolve({ statusCode: res.statusCode, body: JSON.parse(data) });
        } catch (_) {
          resolve({ statusCode: res.statusCode, body: data });
        }
      });
    });

    req.on('error', reject);
    req.setTimeout(15000, () => {
      req.destroy(new Error('Request timed out'));
    });

    if (body) req.write(body);
    req.end();
  });
}

function generateState(userId) {
  const state = crypto.randomBytes(32).toString('hex');
  pendingStates.set(state, { userId, createdAt: Date.now() });
  // Cleanup old entries
  for (const [key, val] of pendingStates.entries()) {
    if (Date.now() - val.createdAt > STATE_TTL_MS) {
      pendingStates.delete(key);
    }
  }
  return state;
}

function validateState(state) {
  const entry = pendingStates.get(state);
  if (!entry) return null;
  pendingStates.delete(state);
  if (Date.now() - entry.createdAt > STATE_TTL_MS) return null;
  return entry.userId;
}

// ============================================================================
// Google Calendar
// ============================================================================

// POST /calendar/google/connect — Initiate Google OAuth
router.post('/google/connect', auth.requireAuth, (req, res) => {
  if (!GOOGLE_CLIENT_ID || !GOOGLE_CLIENT_SECRET) {
    return res.status(503).json({ error: 'Google Calendar integration not configured' });
  }
  if (!tokenCrypto.isEncryptionAvailable()) {
    return res.status(503).json({ error: 'Token encryption not configured' });
  }

  const state = generateState(req.user.id);
  const scopes = [
    'https://www.googleapis.com/auth/calendar.events',
    'https://www.googleapis.com/auth/calendar.readonly',
  ];

  const authUrl = 'https://accounts.google.com/o/oauth2/v2/auth?' + new URLSearchParams({
    client_id: GOOGLE_CLIENT_ID,
    redirect_uri: GOOGLE_REDIRECT_URI,
    response_type: 'code',
    scope: scopes.join(' '),
    access_type: 'offline',
    prompt: 'consent',
    state,
  }).toString();

  return res.json({ authUrl });
});

// GET /calendar/google/callback — Google OAuth callback
router.get('/google/callback', async (req, res) => {
  try {
    const { code, state, error: oauthError } = req.query;

    if (oauthError) {
      return res.status(400).send(`<h3>Calendar connection failed</h3><p>${oauthError}</p><p>You can close this window.</p>`);
    }

    if (!code || !state) {
      return res.status(400).send('<h3>Invalid callback</h3><p>Missing parameters. You can close this window.</p>');
    }

    const userId = validateState(state);
    if (!userId) {
      return res.status(403).send('<h3>Invalid or expired state</h3><p>Please try connecting again. You can close this window.</p>');
    }

    // Exchange code for tokens
    const tokenRes = await httpsRequest('https://oauth2.googleapis.com/token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    }, new URLSearchParams({
      client_id: GOOGLE_CLIENT_ID,
      client_secret: GOOGLE_CLIENT_SECRET,
      code,
      grant_type: 'authorization_code',
      redirect_uri: GOOGLE_REDIRECT_URI,
    }).toString());

    if (tokenRes.statusCode !== 200 || !tokenRes.body.refresh_token) {
      console.error('[Calendar] Google token exchange failed:', tokenRes.body);
      return res.status(502).send('<h3>Failed to connect Google Calendar</h3><p>Token exchange failed. You can close this window.</p>');
    }

    // Encrypt and store refresh token
    const encrypted = tokenCrypto.encryptToken(tokenRes.body.refresh_token);
    if (!encrypted) {
      return res.status(500).send('<h3>Encryption error</h3><p>Please try again. You can close this window.</p>');
    }

    await db.query(
      `UPDATE users
       SET google_refresh_token = $1,
           google_token_key_version = $2,
           google_reauth_required = false
       WHERE id = $3`,
      [encrypted, tokenCrypto.getActiveVersion(), userId]
    );

    console.log(`[Calendar] Google Calendar connected for user ${userId}`);
    return res.send('<h3>Google Calendar connected!</h3><p>You can close this window and return to Inter.</p>');
  } catch (err) {
    console.error('[Calendar] Google callback error:', err);
    return res.status(500).send('<h3>An error occurred</h3><p>Please try again. You can close this window.</p>');
  }
});

// POST /calendar/google/disconnect — Remove Google token
router.post('/google/disconnect', auth.requireAuth, async (req, res) => {
  try {
    await db.query(
      `UPDATE users
       SET google_refresh_token = NULL,
           google_token_key_version = NULL,
           google_reauth_required = false
       WHERE id = $1`,
      [req.user.id]
    );
    return res.json({ ok: true });
  } catch (err) {
    console.error('[Calendar] Google disconnect error:', err);
    return res.status(500).json({ error: 'Failed to disconnect' });
  }
});

// POST /calendar/google/sync/:id — Create Google Calendar event for a meeting
router.post('/google/sync/:id', auth.requireAuth, async (req, res) => {
  try {
    // Fetch user's encrypted refresh token
    const userRow = await db.query(
      'SELECT google_refresh_token, google_reauth_required FROM users WHERE id = $1',
      [req.user.id]
    );

    if (!userRow.rows[0]?.google_refresh_token) {
      return res.status(400).json({ error: 'Google Calendar not connected' });
    }
    if (userRow.rows[0].google_reauth_required) {
      return res.status(401).json({ error: 'Google Calendar re-authentication required' });
    }

    const refreshToken = tokenCrypto.decryptToken(userRow.rows[0].google_refresh_token);
    if (!refreshToken) {
      return res.status(500).json({ error: 'Failed to decrypt calendar token' });
    }

    // Fetch meeting details
    const meetingRow = await db.query(
      'SELECT * FROM scheduled_meetings WHERE id = $1 AND host_user_id = $2',
      [req.params.id, req.user.id]
    );

    if (meetingRow.rows.length === 0) {
      return res.status(404).json({ error: 'Meeting not found' });
    }

    const meeting = meetingRow.rows[0];

    // Get access token from refresh token
    const tokenRes = await httpsRequest('https://oauth2.googleapis.com/token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    }, new URLSearchParams({
      client_id: GOOGLE_CLIENT_ID,
      client_secret: GOOGLE_CLIENT_SECRET,
      refresh_token: refreshToken,
      grant_type: 'refresh_token',
    }).toString());

    if (tokenRes.statusCode !== 200) {
      console.error('[Calendar] Google token refresh failed:', tokenRes.body);
      // Mark as needing re-auth if refresh token is invalid
      if (tokenRes.statusCode === 400 || tokenRes.statusCode === 401) {
        await db.query('UPDATE users SET google_reauth_required = true WHERE id = $1', [req.user.id]);
      }
      return res.status(502).json({ error: 'Failed to refresh Google access token' });
    }

    const accessToken = tokenRes.body.access_token;

    // If Google returned a new refresh token, rotate it
    if (tokenRes.body.refresh_token) {
      const newEncrypted = tokenCrypto.encryptToken(tokenRes.body.refresh_token);
      if (newEncrypted) {
        await db.query(
          'UPDATE users SET google_refresh_token = $1, google_token_key_version = $2 WHERE id = $3',
          [newEncrypted, tokenCrypto.getActiveVersion(), req.user.id]
        );
      }
    }

    // Create Google Calendar event
    const startTime = new Date(meeting.scheduled_at);
    const endTime = new Date(startTime.getTime() + meeting.duration_minutes * 60000);

    const eventBody = JSON.stringify({
      summary: meeting.title,
      description: meeting.description
        ? `${meeting.description}\n\nRoom Code: ${meeting.room_code}`
        : `Room Code: ${meeting.room_code}\nJoin in the Inter app using this room code.`,
      start: {
        dateTime: startTime.toISOString(),
        timeZone: meeting.host_timezone,
      },
      end: {
        dateTime: endTime.toISOString(),
        timeZone: meeting.host_timezone,
      },
      reminders: {
        useDefault: false,
        overrides: [
          { method: 'popup', minutes: 5 },
        ],
      },
    });

    const eventRes = await httpsRequest('https://www.googleapis.com/calendar/v3/calendars/primary/events', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${accessToken}`,
        'Content-Type': 'application/json',
      },
    }, eventBody);

    if (eventRes.statusCode !== 200 && eventRes.statusCode !== 201) {
      console.error('[Calendar] Google event creation failed:', eventRes.body);
      return res.status(502).json({ error: 'Failed to create Google Calendar event' });
    }

    console.log(`[Calendar] Google event created: ${eventRes.body.id} for meeting ${meeting.id}`);
    return res.json({
      ok: true,
      googleEventId: eventRes.body.id,
      googleEventLink: eventRes.body.htmlLink,
    });
  } catch (err) {
    console.error('[Calendar] Google sync error:', err);
    return res.status(500).json({ error: 'Calendar sync failed' });
  }
});

// ============================================================================
// Outlook Calendar
// ============================================================================

const OUTLOOK_AUTH_BASE = `https://login.microsoftonline.com/${OUTLOOK_TENANT}/oauth2/v2.0`;

// POST /calendar/outlook/connect — Initiate Outlook OAuth
router.post('/outlook/connect', auth.requireAuth, (req, res) => {
  if (!OUTLOOK_CLIENT_ID || !OUTLOOK_CLIENT_SECRET) {
    return res.status(503).json({ error: 'Outlook Calendar integration not configured' });
  }
  if (!tokenCrypto.isEncryptionAvailable()) {
    return res.status(503).json({ error: 'Token encryption not configured' });
  }

  const state = generateState(req.user.id);
  const scopes = [
    'Calendars.ReadWrite',
    'offline_access',
  ];

  const authUrl = `${OUTLOOK_AUTH_BASE}/authorize?` + new URLSearchParams({
    client_id: OUTLOOK_CLIENT_ID,
    redirect_uri: OUTLOOK_REDIRECT_URI,
    response_type: 'code',
    scope: scopes.join(' '),
    state,
    prompt: 'consent',
  }).toString();

  return res.json({ authUrl });
});

// GET /calendar/outlook/callback — Outlook OAuth callback
router.get('/outlook/callback', async (req, res) => {
  try {
    const { code, state, error: oauthError } = req.query;

    if (oauthError) {
      return res.status(400).send(`<h3>Calendar connection failed</h3><p>${oauthError}</p><p>You can close this window.</p>`);
    }

    if (!code || !state) {
      return res.status(400).send('<h3>Invalid callback</h3><p>Missing parameters. You can close this window.</p>');
    }

    const userId = validateState(state);
    if (!userId) {
      return res.status(403).send('<h3>Invalid or expired state</h3><p>Please try connecting again. You can close this window.</p>');
    }

    // Exchange code for tokens
    const tokenRes = await httpsRequest(`${OUTLOOK_AUTH_BASE}/token`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    }, new URLSearchParams({
      client_id: OUTLOOK_CLIENT_ID,
      client_secret: OUTLOOK_CLIENT_SECRET,
      code,
      grant_type: 'authorization_code',
      redirect_uri: OUTLOOK_REDIRECT_URI,
      scope: 'Calendars.ReadWrite offline_access',
    }).toString());

    if (tokenRes.statusCode !== 200 || !tokenRes.body.refresh_token) {
      console.error('[Calendar] Outlook token exchange failed:', tokenRes.body);
      return res.status(502).send('<h3>Failed to connect Outlook Calendar</h3><p>Token exchange failed. You can close this window.</p>');
    }

    // Encrypt and store refresh token
    const encrypted = tokenCrypto.encryptToken(tokenRes.body.refresh_token);
    if (!encrypted) {
      return res.status(500).send('<h3>Encryption error</h3><p>Please try again. You can close this window.</p>');
    }

    await db.query(
      `UPDATE users
       SET outlook_refresh_token = $1,
           outlook_token_key_version = $2,
           outlook_reauth_required = false
       WHERE id = $3`,
      [encrypted, tokenCrypto.getActiveVersion(), userId]
    );

    console.log(`[Calendar] Outlook Calendar connected for user ${userId}`);
    return res.send('<h3>Outlook Calendar connected!</h3><p>You can close this window and return to Inter.</p>');
  } catch (err) {
    console.error('[Calendar] Outlook callback error:', err);
    return res.status(500).send('<h3>An error occurred</h3><p>Please try again. You can close this window.</p>');
  }
});

// POST /calendar/outlook/disconnect — Remove Outlook token
router.post('/outlook/disconnect', auth.requireAuth, async (req, res) => {
  try {
    await db.query(
      `UPDATE users
       SET outlook_refresh_token = NULL,
           outlook_token_key_version = NULL,
           outlook_reauth_required = false
       WHERE id = $1`,
      [req.user.id]
    );
    return res.json({ ok: true });
  } catch (err) {
    console.error('[Calendar] Outlook disconnect error:', err);
    return res.status(500).json({ error: 'Failed to disconnect' });
  }
});

// POST /calendar/outlook/sync/:id — Create Outlook Calendar event for a meeting
router.post('/outlook/sync/:id', auth.requireAuth, async (req, res) => {
  try {
    // Fetch user's encrypted refresh token
    const userRow = await db.query(
      'SELECT outlook_refresh_token, outlook_reauth_required FROM users WHERE id = $1',
      [req.user.id]
    );

    if (!userRow.rows[0]?.outlook_refresh_token) {
      return res.status(400).json({ error: 'Outlook Calendar not connected' });
    }
    if (userRow.rows[0].outlook_reauth_required) {
      return res.status(401).json({ error: 'Outlook Calendar re-authentication required' });
    }

    const refreshToken = tokenCrypto.decryptToken(userRow.rows[0].outlook_refresh_token);
    if (!refreshToken) {
      return res.status(500).json({ error: 'Failed to decrypt calendar token' });
    }

    // Fetch meeting details
    const meetingRow = await db.query(
      'SELECT * FROM scheduled_meetings WHERE id = $1 AND host_user_id = $2',
      [req.params.id, req.user.id]
    );

    if (meetingRow.rows.length === 0) {
      return res.status(404).json({ error: 'Meeting not found' });
    }

    const meeting = meetingRow.rows[0];

    // Get access token from refresh token
    const tokenRes = await httpsRequest(`${OUTLOOK_AUTH_BASE}/token`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    }, new URLSearchParams({
      client_id: OUTLOOK_CLIENT_ID,
      client_secret: OUTLOOK_CLIENT_SECRET,
      refresh_token: refreshToken,
      grant_type: 'refresh_token',
      scope: 'Calendars.ReadWrite offline_access',
    }).toString());

    if (tokenRes.statusCode !== 200) {
      console.error('[Calendar] Outlook token refresh failed:', tokenRes.body);
      if (tokenRes.statusCode === 400 || tokenRes.statusCode === 401) {
        await db.query('UPDATE users SET outlook_reauth_required = true WHERE id = $1', [req.user.id]);
      }
      return res.status(502).json({ error: 'Failed to refresh Outlook access token' });
    }

    const accessToken = tokenRes.body.access_token;

    // Rotate refresh token if a new one was issued
    if (tokenRes.body.refresh_token) {
      const newEncrypted = tokenCrypto.encryptToken(tokenRes.body.refresh_token);
      if (newEncrypted) {
        await db.query(
          'UPDATE users SET outlook_refresh_token = $1, outlook_token_key_version = $2 WHERE id = $3',
          [newEncrypted, tokenCrypto.getActiveVersion(), req.user.id]
        );
      }
    }

    // Create Outlook Calendar event via Microsoft Graph API
    const startTime = new Date(meeting.scheduled_at);
    const endTime = new Date(startTime.getTime() + meeting.duration_minutes * 60000);

    const eventBody = JSON.stringify({
      subject: meeting.title,
      body: {
        contentType: 'HTML',
        content: meeting.description
          ? `<p>${meeting.description}</p><p>Room Code: <strong>${meeting.room_code}</strong></p>`
          : `<p>Room Code: <strong>${meeting.room_code}</strong></p><p>Join in the Inter app using this room code.</p>`,
      },
      start: {
        dateTime: startTime.toISOString().replace('Z', ''),
        timeZone: meeting.host_timezone,
      },
      end: {
        dateTime: endTime.toISOString().replace('Z', ''),
        timeZone: meeting.host_timezone,
      },
      isReminderOn: true,
      reminderMinutesBeforeStart: 5,
    });

    const eventRes = await httpsRequest('https://graph.microsoft.com/v1.0/me/events', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${accessToken}`,
        'Content-Type': 'application/json',
      },
    }, eventBody);

    if (eventRes.statusCode !== 200 && eventRes.statusCode !== 201) {
      console.error('[Calendar] Outlook event creation failed:', eventRes.body);
      return res.status(502).json({ error: 'Failed to create Outlook Calendar event' });
    }

    console.log(`[Calendar] Outlook event created: ${eventRes.body.id} for meeting ${meeting.id}`);
    return res.json({
      ok: true,
      outlookEventId: eventRes.body.id,
      outlookEventLink: eventRes.body.webLink,
    });
  } catch (err) {
    console.error('[Calendar] Outlook sync error:', err);
    return res.status(500).json({ error: 'Calendar sync failed' });
  }
});

// ============================================================================
// Status endpoint — check connection for both providers
// ============================================================================

router.get('/status', auth.requireAuth, async (req, res) => {
  try {
    const row = await db.query(
      `SELECT
         google_refresh_token IS NOT NULL  AS google_connected,
         google_reauth_required            AS google_reauth_required,
         outlook_refresh_token IS NOT NULL AS outlook_connected,
         outlook_reauth_required           AS outlook_reauth_required
       FROM users WHERE id = $1`,
      [req.user.id]
    );

    if (row.rows.length === 0) {
      return res.status(404).json({ error: 'User not found' });
    }

    const u = row.rows[0];
    return res.json({
      google: {
        connected: u.google_connected,
        reauthRequired: u.google_reauth_required,
        configured: !!GOOGLE_CLIENT_ID,
      },
      outlook: {
        connected: u.outlook_connected,
        reauthRequired: u.outlook_reauth_required,
        configured: !!OUTLOOK_CLIENT_ID,
      },
    });
  } catch (err) {
    console.error('[Calendar] Status check error:', err);
    return res.status(500).json({ error: 'Failed to check calendar status' });
  }
});

module.exports = router;
