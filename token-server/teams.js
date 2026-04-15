// ============================================================================
// Team Management Module — Inter Token Server
// Phase 11.4
//
// Provides Express Router for:
//   POST   /teams                 — Create a team
//   GET    /teams                 — List user's teams
//   GET    /teams/:id             — Get team details + members
//   PATCH  /teams/:id             — Update team name/description
//   DELETE /teams/:id             — Delete team (owner only)
//   POST   /teams/:id/members     — Invite member(s) by email
//   PATCH  /teams/:id/members/:mid — Update member role
//   DELETE /teams/:id/members/:mid — Remove member
//   POST   /teams/:id/members/accept — Accept team invitation
//
// Design:
//   - Owner is the user who created the team
//   - Roles: owner, admin, member
//   - Admins can invite/remove members; only owner can delete team or change roles
//   - Invitations keyed by email; user_id linked when accepted
// ============================================================================

const express = require('express');
const router = express.Router();
const db = require('./db');
const auth = require('./auth');
const { sendTeamInvitationEmail } = require('./mailer');

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function formatTeam(row) {
  return {
    id: row.id,
    name: row.name,
    description: row.description,
    ownerUserId: row.owner_user_id,
    memberCount: parseInt(row.member_count || '0', 10),
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function formatMember(row) {
  return {
    id: row.id,
    teamId: row.team_id,
    userId: row.user_id,
    email: row.email,
    displayName: row.display_name || row.email,
    role: row.role,
    status: row.status,
    invitedAt: row.invited_at,
    joinedAt: row.joined_at,
  };
}

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------

// POST /teams — Create a new team
router.post('/', auth.requireAuth, async (req, res) => {
  try {
    const { name, description } = req.body;

    if (!name || typeof name !== 'string' || name.trim().length === 0) {
      return res.status(400).json({ error: 'Team name is required' });
    }
    if (name.trim().length > 100) {
      return res.status(400).json({ error: 'Team name must be 100 characters or less' });
    }
    if (description && description.length > 500) {
      return res.status(400).json({ error: 'Description must be 500 characters or less' });
    }

    const result = await db.query(
      `INSERT INTO teams (name, owner_user_id, description)
       VALUES ($1, $2, $3)
       RETURNING *`,
      [name.trim(), req.user.id, description?.trim() || null]
    );

    const team = result.rows[0];

    // Add owner as first member
    await db.query(
      `INSERT INTO team_members (team_id, user_id, email, role, status, joined_at)
       VALUES ($1, $2, $3, 'owner', 'active', NOW())`,
      [team.id, req.user.id, req.user.email]
    );

    return res.status(201).json(formatTeam({ ...team, member_count: '1' }));
  } catch (err) {
    console.error('[Teams] Create error:', err);
    return res.status(500).json({ error: 'Failed to create team' });
  }
});

// GET /teams — List user's teams
router.get('/', auth.requireAuth, async (req, res) => {
  try {
    const result = await db.query(
      `SELECT t.*, COUNT(tm2.id)::TEXT AS member_count
       FROM teams t
       JOIN team_members tm ON tm.team_id = t.id AND tm.user_id = $1 AND tm.status = 'active'
       LEFT JOIN team_members tm2 ON tm2.team_id = t.id AND tm2.status = 'active'
       GROUP BY t.id
       ORDER BY t.created_at DESC`,
      [req.user.id]
    );

    return res.json({ teams: result.rows.map(formatTeam) });
  } catch (err) {
    console.error('[Teams] List error:', err);
    return res.status(500).json({ error: 'Failed to list teams' });
  }
});

// GET /teams/:id — Get team details + members
router.get('/:id', auth.requireAuth, async (req, res) => {
  try {
    // Check membership
    const memberCheck = await db.query(
      `SELECT role FROM team_members
       WHERE team_id = $1 AND user_id = $2 AND status = 'active'`,
      [req.params.id, req.user.id]
    );

    if (memberCheck.rows.length === 0) {
      return res.status(403).json({ error: 'Not a member of this team' });
    }

    const teamResult = await db.query('SELECT * FROM teams WHERE id = $1', [req.params.id]);
    if (teamResult.rows.length === 0) {
      return res.status(404).json({ error: 'Team not found' });
    }

    const membersResult = await db.query(
      `SELECT tm.*, u.display_name
       FROM team_members tm
       LEFT JOIN users u ON u.id = tm.user_id
       WHERE tm.team_id = $1
       ORDER BY tm.role = 'owner' DESC, tm.role = 'admin' DESC, tm.invited_at ASC`,
      [req.params.id]
    );

    const team = teamResult.rows[0];
    team.member_count = membersResult.rows.filter(m => m.status === 'active').length.toString();

    return res.json({
      team: formatTeam(team),
      members: membersResult.rows.map(formatMember),
      callerRole: memberCheck.rows[0].role,
    });
  } catch (err) {
    console.error('[Teams] Get error:', err);
    return res.status(500).json({ error: 'Failed to get team' });
  }
});

// PATCH /teams/:id — Update team name/description
router.patch('/:id', auth.requireAuth, async (req, res) => {
  try {
    // Only owner or admin can update
    const memberCheck = await db.query(
      `SELECT role FROM team_members
       WHERE team_id = $1 AND user_id = $2 AND status = 'active' AND role IN ('owner', 'admin')`,
      [req.params.id, req.user.id]
    );

    if (memberCheck.rows.length === 0) {
      return res.status(403).json({ error: 'Only team owner or admin can update the team' });
    }

    const updates = {};
    if (req.body.name !== undefined) {
      if (typeof req.body.name !== 'string' || req.body.name.trim().length === 0) {
        return res.status(400).json({ error: 'Team name cannot be empty' });
      }
      if (req.body.name.trim().length > 100) {
        return res.status(400).json({ error: 'Team name must be 100 characters or less' });
      }
      updates.name = req.body.name.trim();
    }
    if (req.body.description !== undefined) {
      if (req.body.description && req.body.description.length > 500) {
        return res.status(400).json({ error: 'Description must be 500 characters or less' });
      }
      updates.description = req.body.description?.trim() || null;
    }

    if (Object.keys(updates).length === 0) {
      return res.status(400).json({ error: 'Nothing to update' });
    }

    const setClauses = [];
    const params = [];
    let idx = 1;
    for (const [key, value] of Object.entries(updates)) {
      setClauses.push(`${key} = $${idx}`);
      params.push(value);
      idx++;
    }
    params.push(req.params.id);

    const result = await db.query(
      `UPDATE teams SET ${setClauses.join(', ')} WHERE id = $${idx} RETURNING *`,
      params
    );

    if (result.rows.length === 0) {
      return res.status(404).json({ error: 'Team not found' });
    }

    return res.json(formatTeam(result.rows[0]));
  } catch (err) {
    console.error('[Teams] Update error:', err);
    return res.status(500).json({ error: 'Failed to update team' });
  }
});

// DELETE /teams/:id — Delete team (owner only)
router.delete('/:id', auth.requireAuth, async (req, res) => {
  try {
    const memberCheck = await db.query(
      `SELECT role FROM team_members
       WHERE team_id = $1 AND user_id = $2 AND role = 'owner'`,
      [req.params.id, req.user.id]
    );

    if (memberCheck.rows.length === 0) {
      return res.status(403).json({ error: 'Only the team owner can delete the team' });
    }

    await db.query('DELETE FROM teams WHERE id = $1', [req.params.id]);
    return res.json({ ok: true });
  } catch (err) {
    console.error('[Teams] Delete error:', err);
    return res.status(500).json({ error: 'Failed to delete team' });
  }
});

// POST /teams/:id/members — Invite member(s)
router.post('/:id/members', auth.requireAuth, async (req, res) => {
  try {
    // Only owner or admin can invite
    const memberCheck = await db.query(
      `SELECT role FROM team_members
       WHERE team_id = $1 AND user_id = $2 AND status = 'active' AND role IN ('owner', 'admin')`,
      [req.params.id, req.user.id]
    );

    if (memberCheck.rows.length === 0) {
      return res.status(403).json({ error: 'Only team owner or admin can invite members' });
    }

    const { emails } = req.body;
    if (!Array.isArray(emails) || emails.length === 0) {
      return res.status(400).json({ error: 'emails array is required' });
    }
    if (emails.length > 50) {
      return res.status(400).json({ error: 'Maximum 50 invitations at a time' });
    }

    // Validate email format
    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    for (const email of emails) {
      if (!emailRegex.test(email)) {
        return res.status(400).json({ error: `Invalid email: ${email}` });
      }
    }

    // Get team info for the invitation email
    const teamRow = await db.query('SELECT name FROM teams WHERE id = $1', [req.params.id]);
    if (teamRow.rows.length === 0) {
      return res.status(404).json({ error: 'Team not found' });
    }

    const added = [];
    for (const email of emails) {
      const normalized = email.toLowerCase().trim();
      try {
        // Check if user exists
        const userRow = await db.query('SELECT id FROM users WHERE LOWER(email) = $1', [normalized]);
        const userId = userRow.rows[0]?.id || null;

        await db.query(
          `INSERT INTO team_members (team_id, user_id, email, role, status)
           VALUES ($1, $2, $3, 'member', 'pending')
           ON CONFLICT (team_id, email) DO NOTHING`,
          [req.params.id, userId, normalized]
        );
        added.push(normalized);

        // Fire-and-forget email
        if (typeof sendTeamInvitationEmail === 'function') {
          sendTeamInvitationEmail(normalized, {
            teamName: teamRow.rows[0].name,
            inviterName: req.user.display_name || req.user.email,
          }).catch(err => console.error('[Teams] Invitation email failed:', err));
        }
      } catch (err) {
        console.error(`[Teams] Failed to invite ${normalized}:`, err.message);
      }
    }

    return res.json({ invited: added.length, emails: added });
  } catch (err) {
    console.error('[Teams] Invite error:', err);
    return res.status(500).json({ error: 'Failed to invite members' });
  }
});

// PATCH /teams/:id/members/:mid — Update member role
router.patch('/:id/members/:mid', auth.requireAuth, async (req, res) => {
  try {
    // Only owner can change roles
    const ownerCheck = await db.query(
      `SELECT role FROM team_members
       WHERE team_id = $1 AND user_id = $2 AND role = 'owner'`,
      [req.params.id, req.user.id]
    );

    if (ownerCheck.rows.length === 0) {
      return res.status(403).json({ error: 'Only the team owner can change member roles' });
    }

    const { role } = req.body;
    if (!role || !['admin', 'member'].includes(role)) {
      return res.status(400).json({ error: 'Role must be "admin" or "member"' });
    }

    // Cannot change owner role
    const targetMember = await db.query(
      'SELECT role FROM team_members WHERE id = $1 AND team_id = $2',
      [req.params.mid, req.params.id]
    );

    if (targetMember.rows.length === 0) {
      return res.status(404).json({ error: 'Member not found' });
    }
    if (targetMember.rows[0].role === 'owner') {
      return res.status(400).json({ error: 'Cannot change the owner role' });
    }

    await db.query(
      'UPDATE team_members SET role = $1 WHERE id = $2 AND team_id = $3',
      [role, req.params.mid, req.params.id]
    );

    return res.json({ ok: true });
  } catch (err) {
    console.error('[Teams] Role update error:', err);
    return res.status(500).json({ error: 'Failed to update role' });
  }
});

// DELETE /teams/:id/members/:mid — Remove member
router.delete('/:id/members/:mid', auth.requireAuth, async (req, res) => {
  try {
    // Owner or admin can remove. Members can remove themselves.
    const callerCheck = await db.query(
      `SELECT role FROM team_members
       WHERE team_id = $1 AND user_id = $2 AND status = 'active'`,
      [req.params.id, req.user.id]
    );

    if (callerCheck.rows.length === 0) {
      return res.status(403).json({ error: 'Not a member of this team' });
    }

    const targetMember = await db.query(
      'SELECT * FROM team_members WHERE id = $1 AND team_id = $2',
      [req.params.mid, req.params.id]
    );

    if (targetMember.rows.length === 0) {
      return res.status(404).json({ error: 'Member not found' });
    }

    const callerRole = callerCheck.rows[0].role;
    const target = targetMember.rows[0];

    // Cannot remove the owner
    if (target.role === 'owner') {
      return res.status(400).json({ error: 'Cannot remove the team owner' });
    }

    // Members can only remove themselves
    const isSelf = target.user_id === req.user.id;
    if (callerRole === 'member' && !isSelf) {
      return res.status(403).json({ error: 'Only owner or admin can remove other members' });
    }

    await db.query(
      "UPDATE team_members SET status = 'removed' WHERE id = $1",
      [req.params.mid]
    );

    return res.json({ ok: true });
  } catch (err) {
    console.error('[Teams] Remove error:', err);
    return res.status(500).json({ error: 'Failed to remove member' });
  }
});

// POST /teams/:id/members/accept — Accept team invitation
router.post('/:id/members/accept', auth.requireAuth, async (req, res) => {
  try {
    const result = await db.query(
      `UPDATE team_members
       SET status = 'active', user_id = $1, joined_at = NOW()
       WHERE team_id = $2 AND LOWER(email) = LOWER($3) AND status = 'pending'
       RETURNING *`,
      [req.user.id, req.params.id, req.user.email]
    );

    if (result.rows.length === 0) {
      return res.status(404).json({ error: 'No pending invitation found for your email' });
    }

    return res.json({ ok: true, member: formatMember(result.rows[0]) });
  } catch (err) {
    console.error('[Teams] Accept error:', err);
    return res.status(500).json({ error: 'Failed to accept invitation' });
  }
});

module.exports = router;
