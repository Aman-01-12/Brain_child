// ============================================================================
// PostgreSQL Client — Inter Token Server
// Phase 6.2 [G6.2.2]
//
// Connection pool with graceful error handling.
// Uses DATABASE_URL env var (defaults to localhost for development).
// ============================================================================

const { Pool } = require('pg');

const DATABASE_URL = process.env.DATABASE_URL || 'postgresql://localhost:5432/inter_dev';

const pool = new Pool({
  connectionString: DATABASE_URL,
  max: 10,                  // Max connections in pool
  idleTimeoutMillis: 30000, // Close idle connections after 30s
  connectionTimeoutMillis: 5000, // Fail if connection takes > 5s
});

pool.on('connect', () => {
  // Logged once per new connection — not per query
});

pool.on('error', (err) => {
  console.error('[postgres] Unexpected pool error:', err.message);
});

// ---------------------------------------------------------------------------
// Query helper — use pool.query() for simple queries
// For transactions, use pool.connect() to get a client
// ---------------------------------------------------------------------------
module.exports = {
  query: (text, params) => pool.query(text, params),
  getClient: () => pool.connect(),
  pool,
};
