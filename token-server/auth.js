// ============================================================================
// Authentication Module — Inter Token Server
// Phase 6.3 [G6.3.2]
//
// Provides:
//   register(email, password, displayName)  — create user, return JWT
//   login(email, password)                  — verify credentials, return JWT
//   authenticateToken                       — Express middleware (optional)
//   requireTier(tier)                       — Express middleware (tier gating)
//
// Design:
//   - User auth JWTs are separate from LiveKit room JWTs
//   - Auth is ADDITIVE — anonymous users still work (middleware is optional)
//   - Password hashing uses bcryptjs (12 rounds)
//   - JWTs expire in 7 days (configurable)
// ============================================================================

const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const db = require('./db');

// ---------------------------------------------------------------------------
// Secret validation — crash at startup rather than run with a weak secret.
// Generate a suitable secret:
//   node -e "console.log(require('crypto').randomBytes(32).toString('base64url'))"
// ---------------------------------------------------------------------------
const JWT_SECRET = process.env.JWT_SECRET;
if (!JWT_SECRET || Buffer.from(JWT_SECRET, 'utf8').length < 32) {
  console.error('[FATAL] JWT_SECRET must be set and at least 32 bytes. Server will not start.');
  console.error('[FATAL] Generate one with: node -e "console.log(require(\'crypto\').randomBytes(32).toString(\'base64url\'))"');
  process.exit(1);
}

const JWT_EXPIRES_IN = '7d';   // Phase B: shorten to '15m' when refresh token flow is built
const BCRYPT_ROUNDS = 12;

// ---------------------------------------------------------------------------
// Generate a user auth JWT (NOT a LiveKit token)
// ---------------------------------------------------------------------------
function generateAuthToken(user) {
  return jwt.sign(
    {
      userId:      user.id,
      email:       user.email,
      displayName: user.display_name,
      tier:        user.tier,
    },
    JWT_SECRET,
    {
      algorithm:  'HS256',               // pin — never allow library to negotiate algorithm
      expiresIn:  JWT_EXPIRES_IN,
      issuer:     'inter-token-server',  // validated on verify — prevents cross-service reuse
      audience:   'inter-macos-client', // validated on verify — prevents token misuse
    }
  );
}

// ---------------------------------------------------------------------------
// Register — create new user account
// Returns: { user, token }
// Throws: if email already exists or validation fails
// ---------------------------------------------------------------------------
async function register(email, password, displayName) {
  // Validate inputs
  if (!email || !password || !displayName) {
    throw new Error('email, password, and displayName are required');
  }
  if (password.length < 8) {
    throw new Error('Password must be at least 8 characters');
  }

  const emailNormalized = email.toLowerCase().trim();

  // Check if email already exists
  const existing = await db.query('SELECT id FROM users WHERE email = $1', [emailNormalized]);
  if (existing.rows.length > 0) {
    throw new Error('Email already registered');
  }

  // Hash password
  const passwordHash = await bcrypt.hash(password, BCRYPT_ROUNDS);

  // Insert user
  const result = await db.query(
    `INSERT INTO users (email, display_name, password_hash)
     VALUES ($1, $2, $3)
     RETURNING id, email, display_name, tier, created_at`,
    [emailNormalized, displayName.trim(), passwordHash]
  );

  const user = result.rows[0];
  const token = generateAuthToken(user);

  return {
    user: {
      id: user.id,
      email: user.email,
      displayName: user.display_name,
      tier: user.tier,
      createdAt: user.created_at,
    },
    token,
  };
}

// ---------------------------------------------------------------------------
// Login — verify credentials and return JWT
// Returns: { user, token }
// Throws: if credentials are invalid
// ---------------------------------------------------------------------------
async function login(email, password) {
  if (!email || !password) {
    throw new Error('email and password are required');
  }

  const emailNormalized = email.toLowerCase().trim();

  const result = await db.query(
    'SELECT id, email, display_name, password_hash, tier, created_at FROM users WHERE email = $1',
    [emailNormalized]
  );

  if (result.rows.length === 0) {
    throw new Error('Invalid email or password');
  }

  const user = result.rows[0];
  const isValid = await bcrypt.compare(password, user.password_hash);

  if (!isValid) {
    throw new Error('Invalid email or password');
  }

  const token = generateAuthToken(user);

  return {
    user: {
      id: user.id,
      email: user.email,
      displayName: user.display_name,
      tier: user.tier,
      createdAt: user.created_at,
    },
    token,
  };
}

// ---------------------------------------------------------------------------
// Middleware: authenticateToken (OPTIONAL)
//
// Checks for Authorization: Bearer <token> header.
// If present and valid → attaches req.user = { userId, email, displayName, tier }
// If absent → req.user = null (anonymous — continues without error)
// If present but invalid → 401 Unauthorized
// ---------------------------------------------------------------------------
function authenticateToken(req, res, next) {
  const authHeader = req.headers['authorization'];

  if (!authHeader) {
    // No auth header — anonymous user, continue
    req.user = null;
    return next();
  }

  const token = authHeader.startsWith('Bearer ')
    ? authHeader.slice(7)
    : authHeader;

  try {
    const decoded = jwt.verify(token, JWT_SECRET, {
      algorithms: ['HS256'],              // whitelist — rejects alg:none, RS256, ES256 forgeries
      issuer:     'inter-token-server',   // must match what generateAuthToken sets
      audience:   'inter-macos-client',  // must match what generateAuthToken sets
    });
    req.user = {
      userId:      decoded.userId,
      email:       decoded.email,
      displayName: decoded.displayName,
      tier:        decoded.tier,
    };
    next();
  } catch (err) {
    if (err.name === 'TokenExpiredError') {
      // Expired — distinguish from invalid so clients can trigger silent refresh (Phase B)
      return res.status(401).json({ error: 'Access token expired', code: 'TOKEN_EXPIRED' });
    }
    // Tampered, wrong issuer, wrong audience, or structurally invalid
    return res.status(401).json({ error: 'Invalid auth token', code: 'TOKEN_INVALID' });
  }
}

// ---------------------------------------------------------------------------
// Middleware: requireAuth
//
// Must be used AFTER authenticateToken. Returns 401 if req.user is null.
// Use this for endpoints that REQUIRE authentication.
// ---------------------------------------------------------------------------
function requireAuth(req, res, next) {
  if (!req.user) {
    return res.status(401).json({ error: 'Authentication required' });
  }
  next();
}

// ---------------------------------------------------------------------------
// Middleware Factory: requireTier(minTier)
//
// Checks req.user.tier against a tier hierarchy: free < pro < hiring.
// Returns 403 if user's tier is insufficient.
// Must be used AFTER authenticateToken + requireAuth.
// ---------------------------------------------------------------------------
const TIER_LEVELS = { free: 0, pro: 1, hiring: 2 };

function requireTier(minTier) {
  return (req, res, next) => {
    if (!req.user) {
      return res.status(401).json({ error: 'Authentication required' });
    }

    const userLevel = TIER_LEVELS[req.user.tier] ?? 0;
    const requiredLevel = TIER_LEVELS[minTier] ?? 0;

    if (userLevel < requiredLevel) {
      return res.status(403).json({
        error: `This feature requires a ${minTier} plan or higher`,
        currentTier: req.user.tier,
        requiredTier: minTier,
      });
    }

    next();
  };
}

module.exports = {
  register,
  login,
  authenticateToken,
  requireAuth,
  requireTier,
};
