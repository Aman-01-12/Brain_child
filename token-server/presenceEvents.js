// ============================================================================
// presenceEvents.js — PRESENCE MONITORING (provisional)
//
// The ingest contract for POST /presence/events: a strict allowlist validator
// plus an explicit, tested list of concepts this endpoint refuses to carry.
//
// Pure: no I/O, no DB, no Redis, no clock. This is the anti-drift function (the
// joinGuards.js pattern) — the one place that decides what may enter the store.
// ============================================================================

const EVENT_TYPES = Object.freeze([
  'face_absent',
  'multiple_faces',
  'image_quality_insufficient',
  'camera_disabled',
  'camera_enabled',
  'monitoring_gap',
]);

// What a CLIENT may send. monitoring_gap is server-generated only: it exists so
// client silence is visible rather than indistinguishable from a clean session,
// which a client must not be able to forge or suppress.
const CLIENT_EVENT_TYPES = Object.freeze([
  'face_absent',
  'multiple_faces',
  'image_quality_insufficient',
  'camera_disabled',
  'camera_enabled',
]);

// head_off_axis is a later phase and OUT OF SCOPE. It is absent from both lists
// AND from the CHECK constraint in migration 023, so neither the API nor the
// database will accept it.

const ALLOWED_EVENT_KEYS = Object.freeze([
  'eventType', 'startedAt', 'endedAt', 'durationMs', 'detectorVersion',
]);

// Top-level body keys. `thresholds` is NOT accepted from the client — the server
// stamps it from the session row.
const ALLOWED_BODY_KEYS = Object.freeze(['roomCode', 'identity', 'events']);

// A payload containing ANY of these keys is REJECTED with 400
// PRESENCE_FORBIDDEN_FIELD — never silently dropped. The strict allowlist above
// is the actual security control; THIS list is the documentation control, so a
// future contributor trying to smuggle affect inference through this endpoint
// gets a failing test that names the prohibited concept instead of a generic
// "unknown key". EU AI Act Art. 5(1)(f) makes emotion inference in a hiring
// context a PROHIBITED practice and binds this product as provider.
const FORBIDDEN_KEYS = Object.freeze([
  // landmarks / meshes / templates — no geometry beyond a bounding box, ever
  'landmarks', 'landmark', 'landmarkpoints', 'mesh', 'facemesh',
  'blendshapes', 'blendshape', 'embedding', 'embeddings', 'template',
  'faceprint', 'featureprint', 'descriptor', 'vector',
  // scores / aggregates / rankings — no score ever
  'score', 'scores', 'suspicionscore', 'integrityscore', 'riskscore',
  'risklevel', 'rating', 'index', 'percentile', 'rank', 'aggregate', 'total',
  // affect / emotion — prohibited practice
  'emotion', 'emotions', 'affect', 'sentiment', 'mood', 'expression', 'valence',
  'arousal',
  // cognition / attitude — the Guidelines treat attitude as equivalent to emotion
  'attention', 'attentive', 'attentionscore', 'engagement', 'engaged',
  'focus', 'distraction', 'interest', 'confidence', 'nervousness', 'stress',
  'anxiety', 'honesty', 'deception', 'personality', 'trait', 'traits',
  // gaze / iris / blink — refused permanently
  'gaze', 'gazedirection', 'iris', 'pupil', 'pupils', 'eyeaspectratio', 'ear',
  'blink', 'blinks', 'eyesclosed',
  // head pose — out of scope, not collected
  'yaw', 'pitch', 'roll', 'headpose', 'pose', 'orientation',
  // pixels — never transmitted, in any form
  'frame', 'frames', 'image', 'images', 'jpeg', 'jpg', 'png', 'pixels',
  'pixelbuffer', 'crop', 'crops', 'thumbnail', 'snapshot', 'base64', 'bytes',
]);

// Matching: normalise(key) = key.toLowerCase().replace(/[_-]/g, '')
// Applied RECURSIVELY to every object key at every depth, including objects
// inside arrays. So {"meta":{"face_score":1}} and [{"Gaze-Direction":…}] are
// both caught. Forbidden wins over unknown so the error names the concept.

const MAX_BATCH = 100;
const MAX_SCAN_DEPTH = 16;        // bounds the recursive walk against a hostile payload
const MAX_IDENTITY_LENGTH = 128;  // interview_presence_sessions.participant_identity
const MAX_ROOM_CODE_LENGTH = 16;
const MAX_DETECTOR_VERSION_LENGTH = 64;

function normaliseKey(key) {
  return String(key).toLowerCase().replace(/[_-]/g, '');
}

const FORBIDDEN_NORMALISED = new Set(FORBIDDEN_KEYS.map(normaliseKey));

/// Walk `value` and return the FIRST forbidden key encountered (as written by
/// the caller, so the error can name it), or null. Recurses through objects and
/// arrays alike.
function findForbiddenKey(value, depth = 0) {
  if (value === null || typeof value !== 'object' || depth > MAX_SCAN_DEPTH) return null;
  if (Array.isArray(value)) {
    for (const item of value) {
      const hit = findForbiddenKey(item, depth + 1);
      if (hit !== null) return hit;
    }
    return null;
  }
  for (const key of Object.keys(value)) {
    if (FORBIDDEN_NORMALISED.has(normaliseKey(key))) return key;
    const hit = findForbiddenKey(value[key], depth + 1);
    if (hit !== null) return hit;
  }
  return null;
}

function reject(status, code, error, field) {
  const out = { ok: false, status, code, error };
  if (field !== undefined) out.field = field;
  return out;
}

/// Parse an ISO-8601 date-time string into { ms, iso } or null.
///
/// Timestamps cross the wire as ISO-8601 strings ONLY. Numbers are refused
/// deliberately: an epoch number is ambiguous between seconds and milliseconds,
/// and silently guessing wrong would mis-stamp the one thing an event is — a
/// fact about a moment in time.
function parseInstant(value) {
  if (typeof value !== 'string' || value.trim().length === 0) return null;
  const ms = Date.parse(value);
  if (!Number.isFinite(ms)) return null;
  return { ms, iso: new Date(ms).toISOString() };
}

/// Validate a client ingest batch.
///
/// Returns { ok: true, roomCode, identity, events } where every event is
/// normalised to { eventType, startedAt (ISO), endedAt (ISO), durationMs }, or
/// { ok: false, status, code, error, field? }.
///
/// NOTE: an empty `events` array is VALID. The client reports on a fixed cadence
/// whether or not anything happened, so an empty batch is a heartbeat that says
/// "still here, nothing to report" — which is exactly what makes real silence
/// meaningful enough for the server to record a monitoring_gap.
function validateEventBatch(body, { multipleFacesEnabled = false } = {}) {
  if (body === null || typeof body !== 'object' || Array.isArray(body)) {
    return reject(400, 'PRESENCE_PAYLOAD_INVALID', 'Request body must be an object.');
  }

  // Forbidden keys are scanned FIRST, over the WHOLE payload at every depth, so
  // the response names the prohibited concept rather than reporting a generic
  // unknown key from somewhere shallower.
  const forbidden = findForbiddenKey(body);
  if (forbidden !== null) {
    return reject(
      400,
      'PRESENCE_FORBIDDEN_FIELD',
      `The field '${forbidden}' is not accepted by this endpoint and is never recorded.`,
      forbidden
    );
  }

  for (const key of Object.keys(body)) {
    if (!ALLOWED_BODY_KEYS.includes(key)) {
      return reject(400, 'PRESENCE_UNKNOWN_FIELD', `Unexpected field '${key}'.`, key);
    }
  }

  const { roomCode, identity, events } = body;

  if (typeof roomCode !== 'string' || roomCode.length === 0 || roomCode.length > MAX_ROOM_CODE_LENGTH) {
    return reject(400, 'PRESENCE_PAYLOAD_INVALID', 'roomCode is required.', 'roomCode');
  }
  if (typeof identity !== 'string' || identity.length === 0 || identity.length > MAX_IDENTITY_LENGTH) {
    return reject(400, 'PRESENCE_PAYLOAD_INVALID', 'identity is required.', 'identity');
  }
  if (!Array.isArray(events)) {
    return reject(400, 'PRESENCE_PAYLOAD_INVALID', 'events must be an array.', 'events');
  }
  if (events.length > MAX_BATCH) {
    return reject(413, 'PRESENCE_BATCH_TOO_LARGE', `A batch may contain at most ${MAX_BATCH} events.`, 'events');
  }

  const normalised = [];
  for (let i = 0; i < events.length; i++) {
    const raw = events[i];
    if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
      return reject(400, 'PRESENCE_PAYLOAD_INVALID', `events[${i}] must be an object.`, `events[${i}]`);
    }
    for (const key of Object.keys(raw)) {
      if (!ALLOWED_EVENT_KEYS.includes(key)) {
        return reject(400, 'PRESENCE_UNKNOWN_FIELD', `Unexpected field '${key}' in events[${i}].`, key);
      }
    }

    const { eventType, startedAt, endedAt, durationMs, detectorVersion } = raw;

    if (typeof eventType !== 'string' || !CLIENT_EVENT_TYPES.includes(eventType)) {
      return reject(
        400,
        'PRESENCE_EVENT_TYPE_NOT_ALLOWED',
        `eventType '${String(eventType)}' is not accepted from a client.`,
        'eventType'
      );
    }
    if (eventType === 'multiple_faces' && multipleFacesEnabled !== true) {
      return reject(
        409,
        'PRESENCE_EVENT_TYPE_DISABLED',
        "The 'multiple_faces' signal is not enabled for this room.",
        'eventType'
      );
    }

    const started = parseInstant(startedAt);
    if (started === null) {
      return reject(400, 'PRESENCE_PAYLOAD_INVALID',
        `events[${i}].startedAt must be an ISO-8601 date-time string.`, 'startedAt');
    }
    // endedAt is optional: the instantaneous camera transitions end when they start.
    const ended = (endedAt === undefined || endedAt === null) ? started : parseInstant(endedAt);
    if (ended === null) {
      return reject(400, 'PRESENCE_PAYLOAD_INVALID',
        `events[${i}].endedAt must be an ISO-8601 date-time string.`, 'endedAt');
    }
    if (ended.ms < started.ms) {
      return reject(400, 'PRESENCE_PAYLOAD_INVALID',
        `events[${i}].endedAt must not precede startedAt.`, 'endedAt');
    }

    // durationMs is optional and derived when absent; when present it must be a
    // non-negative integer.
    let duration;
    if (durationMs === undefined || durationMs === null) {
      duration = ended.ms - started.ms;
    } else if (typeof durationMs === 'number' && Number.isInteger(durationMs) && durationMs >= 0) {
      duration = durationMs;
    } else {
      return reject(400, 'PRESENCE_PAYLOAD_INVALID',
        `events[${i}].durationMs must be a non-negative integer.`, 'durationMs');
    }

    // detectorVersion is accepted for provenance but NEVER stored from here —
    // the server stamps the session's own version onto every row.
    if (detectorVersion !== undefined && detectorVersion !== null &&
        (typeof detectorVersion !== 'string' || detectorVersion.length > MAX_DETECTOR_VERSION_LENGTH)) {
      return reject(400, 'PRESENCE_PAYLOAD_INVALID',
        `events[${i}].detectorVersion must be a short string.`, 'detectorVersion');
    }

    normalised.push({
      eventType,
      startedAt: started.iso,
      endedAt: ended.iso,
      durationMs: duration,
    });
  }

  return { ok: true, roomCode, identity, events: normalised };
}

module.exports = {
  EVENT_TYPES,
  CLIENT_EVENT_TYPES,
  ALLOWED_EVENT_KEYS,
  ALLOWED_BODY_KEYS,
  FORBIDDEN_KEYS,
  MAX_BATCH,
  normaliseKey,
  findForbiddenKey,
  validateEventBatch,
};
