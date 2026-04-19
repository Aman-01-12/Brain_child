// ============================================================================
// Idempotency Middleware — Inter Token Server
// Network Resilience T1: Two Generals' Problem
//
// Prevents duplicate side effects from retried state-mutating requests.
// Clients send an `X-Idempotency-Key` header (UUID v4). The middleware
// caches the response in Redis for 24 hours. Replayed keys return the
// cached response without re-executing the handler.
//
// Usage:
//   const { requireIdempotencyKey } = require('./idempotency');
//   router.post('/schedule', requireAuth, requireIdempotencyKey, handler);
// ============================================================================

const redis = require('./redis');

const IDEMPOTENCY_TTL = 86400; // 24 hours in seconds
const KEY_PREFIX = 'idempotency:';

// UUID v4 pattern — reject malformed keys to prevent cache pollution.
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

/**
 * Express middleware that enforces idempotency on state-mutating endpoints.
 *
 * Behaviour:
 * 1. If `X-Idempotency-Key` header is missing → 400.
 * 2. If the key has a cached response in Redis → return it immediately (no handler).
 * 3. Otherwise, execute the handler, capture the response, cache it, and return.
 *
 * The key is scoped to the authenticated user (if any) + the request path
 * to prevent cross-user/cross-endpoint collisions.
 */
function requireIdempotencyKey(req, res, next) {
  const clientKey = req.headers['x-idempotency-key'];

  if (!clientKey) {
    return res.status(400).json({
      error: 'Missing X-Idempotency-Key header',
      code: 'IDEMPOTENCY_KEY_REQUIRED',
    });
  }

  if (!UUID_PATTERN.test(clientKey)) {
    return res.status(400).json({
      error: 'X-Idempotency-Key must be a valid UUID v4',
      code: 'IDEMPOTENCY_KEY_INVALID',
    });
  }

  // Scope to user + method + path to prevent cross-endpoint collisions.
  const userId = req.user?.userId || 'anon';
  const scope = `${req.method}:${req.baseUrl}${req.path}`;
  const redisKey = `${KEY_PREFIX}${userId}:${scope}:${clientKey}`;

  redis
    .get(redisKey)
    .then((cached) => {
      if (cached) {
        // Cache hit — return the stored response without re-executing.
        try {
          const { statusCode, body } = JSON.parse(cached);
          return res.status(statusCode).json(body);
        } catch (parseErr) {
          console.error('[idempotency] Corrupted cache entry, treating as miss:', parseErr.message);
          // Fall through to execute handler
        }
      }

      // Cache miss — intercept res.json to capture the response.
      const originalJson = res.json.bind(res);
      res.json = function (body) {
        // Only cache successful (2xx) responses. Error responses should
        // be retryable — the client will send the same key again.
        if (res.statusCode >= 200 && res.statusCode < 300) {
          const payload = JSON.stringify({
            statusCode: res.statusCode,
            body,
          });
          redis
            .set(redisKey, payload, 'EX', IDEMPOTENCY_TTL)
            .catch((err) =>
              console.error('[idempotency] Redis SET error:', err.message)
            );
        }
        return originalJson(body);
      };

      next();
    })
    .catch((err) => {
      // Redis down — fail open (allow the request through).
      // Duplicates are better than a total outage.
      console.error('[idempotency] Redis GET error:', err.message);
      next();
    });
}

module.exports = { requireIdempotencyKey };
