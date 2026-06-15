// ============================================================================
// profile.js — User profile preferences (unified Settings window)
//
// Express Router mounted at /auth in index.js. Provides:
//   GET   /auth/profile — fresh profile read (DB, not JWT) incl. preferences
//   PATCH /auth/profile — update displayName / timezone / language
//
// displayName is carried in the JWT, so after a successful name change the
// client forces one token refresh (the refresh path re-reads users.display_name).
// timezone (IANA, nullable) is consumed by scheduling as the default host
// timezone when set. language is stored for future clients; the macOS app
// ships it as a "coming soon" display until localization lands.
// ============================================================================

const express = require('express');
const db = require('./db');
const auth = require('./auth');

const router = express.Router();

const PROFILE_LANGUAGE_ALLOWLIST = new Set(['en-US']);

function formatProfile(row) {
  return {
    userId: row.id,
    email: row.email,
    displayName: row.display_name,
    tier: row.tier,
    timezone: row.timezone,
    language: row.language,
  };
}

// ---------------------------------------------------------------------------
// GET /auth/profile
// ---------------------------------------------------------------------------
router.get('/profile', auth.requireAuth, async (req, res) => {
  try {
    const result = await db.query(
      `SELECT id, email, display_name, tier, timezone, language
       FROM users WHERE id = $1 AND deleted_at IS NULL`,
      [req.user.userId]
    );
    if (result.rows.length === 0) {
      return res.status(401).json({ error: 'User not found', code: 'USER_NOT_FOUND' });
    }
    res.json(formatProfile(result.rows[0]));
  } catch (err) {
    console.error('[auth] GET /auth/profile error:', err.message);
    res.status(500).json({ error: 'Failed to load profile' });
  }
});

// ---------------------------------------------------------------------------
// PATCH /auth/profile — only provided keys change
// ---------------------------------------------------------------------------
router.patch('/profile', auth.requireAuth, async (req, res) => {
  const body = req.body || {};
  const sets = [];
  const values = [];

  if (body.displayName !== undefined) {
    if (typeof body.displayName !== 'string' || body.displayName.trim().length === 0) {
      return res.status(400).json({ error: 'displayName must be a non-empty string' });
    }
    const name = body.displayName.trim();
    if (name.length > 100) {
      return res.status(400).json({ error: 'displayName must be 100 characters or fewer' });
    }
    values.push(name);
    sets.push(`display_name = $${values.length}`);
  }

  if (body.timezone !== undefined) {
    if (body.timezone === null || body.timezone === '') {
      values.push(null);
      sets.push(`timezone = $${values.length}`);
    } else if (typeof body.timezone === 'string') {
      try {
        Intl.DateTimeFormat(undefined, { timeZone: body.timezone });
      } catch {
        return res.status(400).json({ error: 'timezone must be a valid IANA identifier' });
      }
      values.push(body.timezone);
      sets.push(`timezone = $${values.length}`);
    } else {
      return res.status(400).json({ error: 'timezone must be a string or null' });
    }
  }

  if (body.language !== undefined) {
    if (body.language === null || body.language === '') {
      values.push(null);
      sets.push(`language = $${values.length}`);
    } else if (typeof body.language === 'string' && PROFILE_LANGUAGE_ALLOWLIST.has(body.language)) {
      values.push(body.language);
      sets.push(`language = $${values.length}`);
    } else {
      return res.status(400).json({ error: 'language is not supported' });
    }
  }

  if (sets.length === 0) {
    return res.status(400).json({ error: 'Nothing to update' });
  }

  try {
    values.push(req.user.userId);
    const result = await db.query(
      `UPDATE users SET ${sets.join(', ')}
       WHERE id = $${values.length} AND deleted_at IS NULL
       RETURNING id, email, display_name, tier, timezone, language`,
      values
    );
    if (result.rows.length === 0) {
      return res.status(401).json({ error: 'User not found', code: 'USER_NOT_FOUND' });
    }
    const row = result.rows[0];
    auth.auditLog(row.id, 'profile_update', req.ip, { fields: sets.map(s => s.split(' ')[0]) });
    res.json(formatProfile(row));
  } catch (err) {
    console.error('[auth] PATCH /auth/profile error:', err.message);
    res.status(500).json({ error: 'Failed to update profile' });
  }
});

module.exports = router;
