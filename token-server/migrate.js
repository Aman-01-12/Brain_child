// ============================================================================
// Migration Runner — Inter Token Server
// Phase 6.2 [G6.2.3]
//
// Simple sequential SQL migration runner.
// Usage: node migrate.js
//
// Tracks applied migrations in a `schema_migrations` table.
// Migrations are .sql files in ./migrations/ named sequentially:
//   001_initial_schema.sql, 002_add_indexes.sql, etc.
// ============================================================================

require('dotenv').config();

const fs = require('fs');
const path = require('path');
const db = require('./db');

const MIGRATIONS_DIR = path.join(__dirname, 'migrations');

async function ensureMigrationsTable() {
  await db.query(`
    CREATE TABLE IF NOT EXISTS schema_migrations (
      id          SERIAL PRIMARY KEY,
      filename    VARCHAR(255) UNIQUE NOT NULL,
      applied_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
  `);
}

async function getAppliedMigrations() {
  const result = await db.query('SELECT filename FROM schema_migrations ORDER BY id');
  return new Set(result.rows.map(r => r.filename));
}

async function getPendingMigrations(applied) {
  const files = fs.readdirSync(MIGRATIONS_DIR)
    .filter(f => f.endsWith('.sql'))
    .sort(); // Lexicographic — 001 before 002
  return files.filter(f => !applied.has(f));
}

async function runMigration(filename) {
  const filePath = path.join(MIGRATIONS_DIR, filename);
  const sql = fs.readFileSync(filePath, 'utf-8');

  const client = await db.getClient();
  try {
    await client.query('BEGIN');
    await client.query(sql);
    await client.query(
      'INSERT INTO schema_migrations (filename) VALUES ($1)',
      [filename]
    );
    await client.query('COMMIT');
    console.log(`  ✓ ${filename}`);
  } catch (err) {
    await client.query('ROLLBACK');
    console.error(`  ✗ ${filename}: ${err.message}`);
    throw err;
  } finally {
    client.release();
  }
}

async function migrate() {
  console.log('[migrate] Starting migration...');
  console.log(`[migrate] Database: ${process.env.DATABASE_URL || 'postgresql://localhost:5432/inter_dev'}`);

  await ensureMigrationsTable();
  const applied = await getAppliedMigrations();
  const pending = await getPendingMigrations(applied);

  if (pending.length === 0) {
    console.log('[migrate] No pending migrations.');
  } else {
    console.log(`[migrate] ${pending.length} migration(s) to apply:`);
    for (const filename of pending) {
      await runMigration(filename);
    }
    console.log('[migrate] All migrations applied successfully.');
  }

  await db.pool.end();
}

migrate().catch((err) => {
  console.error('[migrate] Migration failed:', err.message);
  process.exit(1);
});
