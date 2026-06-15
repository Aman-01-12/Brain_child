// ============================================================================
// File Validation — shared upload allowlist for the Inter token server
//
// Single source of truth for which uploaded file types are accepted, used by
// BOTH the in-call chat upload (index.js) and the team chat file upload
// (teams.js). Centralized so the two paths can never drift to different
// allowlists — a divergence would be a security gap (OWASP File Upload).
//
// The MIME passed in MUST be the magic-byte-detected type (e.g. from file-type),
// never the client-supplied Content-Type header, which is trivially spoofed.
// ============================================================================

const path = require('path');

// Allowed MIME prefixes (validated against magic-byte detection, not the client header)
const ALLOWED_MIME_PREFIXES = [
  'image/',
  'application/pdf',
  'text/',
  'application/vnd.',                     // MS Office + OpenDocument formats
  'application/msword',
  'application/vnd.ms-excel',
  'application/vnd.ms-powerpoint',
  'application/rtf',
  'application/zip',                      // .zip archives (often docx/xlsx containers)
  'application/x-zip-compressed',
];

// MIME types that are explicitly blocked regardless of prefix match.
// NOTE: these must include executable MARKUP that would otherwise slip through the
// broad `text/` and `image/` allow-prefixes (stored-XSS vector if ever served inline).
const BLOCKED_MIME_EXACT = new Set([
  'application/x-msdownload',
  'application/x-dosexec',
  'application/x-executable',
  'application/x-mach-binary',
  'application/x-sh',
  'application/x-shellscript',
  'application/x-httpd-php',
  'application/javascript',
  'application/x-javascript',
  'application/x-perl',
  'application/x-python-code',
  // Executable markup — blocked so the `text/` / `image/` prefixes cannot admit them.
  'text/html',
  'text/javascript',
  'text/xml',
  'application/xhtml+xml',
  'image/svg+xml',
]);

function isMimeAllowed(mime) {
  if (!mime) return false;
  const lower = mime.toLowerCase();
  if (BLOCKED_MIME_EXACT.has(lower)) return false;
  return ALLOWED_MIME_PREFIXES.some(prefix => lower.startsWith(prefix));
}

// Sanitize a client-supplied filename for safe display/storage: strip any
// directory components (path traversal), restrict to a safe character subset,
// and cap the length. Never used as a filesystem/S3 key — those are UUIDs.
function sanitizeFilename(rawName) {
  const base = path.basename(String(rawName == null ? 'file' : rawName));
  const safe = base.replace(/[^\w.\-]/g, '_').slice(0, 200);
  return safe.length > 0 ? safe : 'file';
}

module.exports = {
  ALLOWED_MIME_PREFIXES,
  BLOCKED_MIME_EXACT,
  isMimeAllowed,
  sanitizeFilename,
};
