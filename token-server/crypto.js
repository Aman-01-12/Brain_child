// ============================================================================
// Encryption Module — Inter Token Server
// Phase 11.2.4 [G11.2.4]
//
// Key-versioned AES-256-GCM encryption for sensitive tokens (OAuth refresh
// tokens for Google Calendar and Outlook Calendar).
//
// Format:  v{N}:{iv_hex}:{authTag_hex}:{ciphertext_hex}
//
// Env vars:
//   ENCRYPTION_ACTIVE_VERSION  — current write-key version (e.g. "1")
//   ENCRYPTION_SECRET_V1       — 32+ byte hex or base64url key for version 1
//   ENCRYPTION_SECRET_V2       — (future) key for version 2, etc.
//
// If no versioned keys are configured, the module exports no-ops that log
// a warning — this allows the server to start without encryption configured
// (calendar sync will be unavailable until keys are set).
// ============================================================================

const crypto = require('crypto');

const ALGORITHM = 'aes-256-gcm';
const IV_LENGTH = 12;           // 96-bit IV per NIST recommendation for GCM
const AUTH_TAG_LENGTH = 16;     // 128-bit auth tag

// ---------------------------------------------------------------------------
// Key loading
// ---------------------------------------------------------------------------

const activeVersion = process.env.ENCRYPTION_ACTIVE_VERSION
  ? parseInt(process.env.ENCRYPTION_ACTIVE_VERSION, 10)
  : null;

/**
 * Load all available key versions from environment.
 * Keys can be hex (64 chars = 32 bytes) or base64url encoded.
 */
function loadKeys() {
  const keys = {};
  for (let v = 1; v <= 100; v++) {
    const raw = process.env[`ENCRYPTION_SECRET_V${v}`];
    if (!raw) continue;
    const buf = parseKeyBuffer(raw);
    if (buf && buf.length >= 32) {
      keys[v] = buf.slice(0, 32); // exactly 32 bytes for AES-256
    } else {
      console.warn(`[crypto] ENCRYPTION_SECRET_V${v} is present but < 32 bytes — skipped`);
    }
  }
  return keys;
}

function parseKeyBuffer(raw) {
  // Try hex first (64 hex chars = 32 bytes)
  if (/^[0-9a-fA-F]{64,}$/.test(raw)) {
    return Buffer.from(raw, 'hex');
  }
  // Try base64url / base64
  try {
    const buf = Buffer.from(raw, 'base64url');
    if (buf.length >= 32) return buf;
  } catch (_) { /* ignore */ }
  try {
    const buf = Buffer.from(raw, 'base64');
    if (buf.length >= 32) return buf;
  } catch (_) { /* ignore */ }
  // Fall back to utf-8
  return Buffer.from(raw, 'utf8');
}

const keyStore = loadKeys();

// Startup validation
if (activeVersion !== null) {
  if (!keyStore[activeVersion]) {
    console.error(`[crypto] FATAL: ENCRYPTION_ACTIVE_VERSION=${activeVersion} but ENCRYPTION_SECRET_V${activeVersion} is missing or invalid. Calendar token encryption will be unavailable.`);
  } else {
    console.log(`[crypto] Encryption ready — active key version: ${activeVersion}, total keys loaded: ${Object.keys(keyStore).length}`);
  }
} else {
  console.warn('[crypto] ENCRYPTION_ACTIVE_VERSION not set — calendar token encryption unavailable. Set ENCRYPTION_ACTIVE_VERSION and ENCRYPTION_SECRET_V{N} to enable.');
}

// ---------------------------------------------------------------------------
// Encrypt
// ---------------------------------------------------------------------------

/**
 * Encrypt a plaintext string using the active key version.
 * Returns the versioned ciphertext string, or null if encryption is unavailable.
 *
 * @param {string} plaintext
 * @returns {string|null} format: v{N}:{iv_hex}:{authTag_hex}:{ciphertext_hex}
 */
function encryptToken(plaintext) {
  if (activeVersion === null || !keyStore[activeVersion]) {
    console.warn('[crypto] encryptToken called but no active key configured');
    return null;
  }

  const iv = crypto.randomBytes(IV_LENGTH);
  const cipher = crypto.createCipheriv(ALGORITHM, keyStore[activeVersion], iv, {
    authTagLength: AUTH_TAG_LENGTH,
  });

  let encrypted = cipher.update(plaintext, 'utf8', 'hex');
  encrypted += cipher.final('hex');
  const authTag = cipher.getAuthTag().toString('hex');

  return `v${activeVersion}:${iv.toString('hex')}:${authTag}:${encrypted}`;
}

// ---------------------------------------------------------------------------
// Decrypt
// ---------------------------------------------------------------------------

/**
 * Decrypt a versioned ciphertext string.
 * Returns the plaintext, or null if decryption fails.
 *
 * @param {string} blob — format: v{N}:{iv_hex}:{authTag_hex}:{ciphertext_hex}
 * @returns {string|null}
 */
function decryptToken(blob) {
  if (!blob || typeof blob !== 'string') return null;

  const parts = blob.split(':');
  if (parts.length !== 4) {
    console.error('[crypto] Invalid encrypted token format');
    return null;
  }

  const versionStr = parts[0]; // "v1", "v2", etc.
  const version = parseInt(versionStr.replace('v', ''), 10);
  if (isNaN(version) || !keyStore[version]) {
    console.error(`[crypto] Key version ${version} not available — cannot decrypt`);
    return null;
  }

  const iv = Buffer.from(parts[1], 'hex');
  const authTag = Buffer.from(parts[2], 'hex');
  const ciphertext = parts[3];

  try {
    const decipher = crypto.createDecipheriv(ALGORITHM, keyStore[version], iv, {
      authTagLength: AUTH_TAG_LENGTH,
    });
    decipher.setAuthTag(authTag);
    let decrypted = decipher.update(ciphertext, 'hex', 'utf8');
    decrypted += decipher.final('utf8');
    return decrypted;
  } catch (err) {
    console.error(`[crypto] Decryption failed (version ${version}): ${err.message}`);
    return null;
  }
}

// ---------------------------------------------------------------------------
// Helpers for key rotation
// ---------------------------------------------------------------------------

/**
 * Get the active key version number.
 * @returns {number|null}
 */
function getActiveVersion() {
  return activeVersion;
}

/**
 * Check if a specific key version is available.
 * @param {number} version
 * @returns {boolean}
 */
function hasKeyVersion(version) {
  return !!keyStore[version];
}

/**
 * Check if encryption is available (active key configured).
 * @returns {boolean}
 */
function isEncryptionAvailable() {
  return activeVersion !== null && !!keyStore[activeVersion];
}

module.exports = {
  encryptToken,
  decryptToken,
  getActiveVersion,
  hasKeyVersion,
  isEncryptionAvailable,
};
