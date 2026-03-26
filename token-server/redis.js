// ============================================================================
// Redis Client — Inter Token Server
// Phase 6.1 [G6.1.2]
//
// Connection factory with graceful error handling.
// Uses REDIS_URL env var (defaults to localhost for development).
// ============================================================================

const Redis = require('ioredis');

const REDIS_URL = process.env.REDIS_URL || 'redis://localhost:6379';

const redis = new Redis(REDIS_URL, {
  maxRetriesPerRequest: 3,
  retryStrategy(times) {
    if (times > 10) {
      console.error('[redis] Max reconnection attempts reached. Giving up.');
      return null; // Stop retrying
    }
    const delay = Math.min(times * 200, 2000);
    console.log(`[redis] Reconnecting in ${delay}ms (attempt ${times})…`);
    return delay;
  },
  lazyConnect: false, // Connect immediately on creation
});

redis.on('connect', () => {
  console.log(`[redis] Connected to ${REDIS_URL}`);
});

redis.on('error', (err) => {
  console.error('[redis] Connection error:', err.message);
});

redis.on('close', () => {
  console.log('[redis] Connection closed');
});

module.exports = redis;
