// ============================================================================
// presenceEvents — unit tests (node:test). PRESENCE MONITORING (provisional)
//
// The ingest contract for POST /presence/events. Pure logic; no DB, no Redis.
// Each assertion fails if the control is weakened.
//
// The load-bearing ones are the FORBIDDEN_KEYS cases: a payload carrying a
// prohibited concept must be REJECTED and the response must NAME the offending
// field. "ok: true with the key quietly stripped" is a failure, because a
// contributor who smuggles affect inference into this endpoint has to hit a
// failing test that says so rather than a silently-cleaned payload.
// ============================================================================

const { test, describe } = require('node:test');
const assert = require('node:assert');
const {
  EVENT_TYPES,
  CLIENT_EVENT_TYPES,
  FORBIDDEN_KEYS,
  MAX_BATCH,
  normaliseKey,
  validateEventBatch,
} = require('./../presenceEvents');

const T0 = '2026-10-31T10:00:00.000Z';
const T1 = '2026-10-31T10:00:12.000Z';

function body(events, extra = {}) {
  return { roomCode: 'ABCDEF', identity: 'cand-1', events, ...extra };
}

function ev(eventType, extra = {}) {
  return { eventType, startedAt: T0, endedAt: T1, durationMs: 12000, ...extra };
}

describe('event-type allowlist', () => {
  test('every client event type is accepted', () => {
    for (const type of CLIENT_EVENT_TYPES) {
      const opts = { multipleFacesEnabled: true };
      const r = validateEventBatch(body([ev(type)]), opts);
      assert.strictEqual(r.ok, true, `${type} should be accepted`);
      assert.strictEqual(r.events[0].eventType, type);
    }
  });

  test('monitoring_gap from a client is rejected — it is server-generated only', () => {
    assert.ok(EVENT_TYPES.includes('monitoring_gap'));
    assert.ok(!CLIENT_EVENT_TYPES.includes('monitoring_gap'));
    const r = validateEventBatch(body([ev('monitoring_gap')]), {});
    assert.strictEqual(r.ok, false);
    assert.strictEqual(r.status, 400);
    assert.strictEqual(r.code, 'PRESENCE_EVENT_TYPE_NOT_ALLOWED');
  });

  test('head_off_axis is rejected — head pose is out of scope and not ingestible', () => {
    assert.ok(!EVENT_TYPES.includes('head_off_axis'));
    const r = validateEventBatch(body([ev('head_off_axis')]), { multipleFacesEnabled: true });
    assert.strictEqual(r.ok, false);
    assert.strictEqual(r.status, 400);
    assert.strictEqual(r.code, 'PRESENCE_EVENT_TYPE_NOT_ALLOWED');
  });

  test('an unknown event type is rejected', () => {
    const r = validateEventBatch(body([ev('looked_away')]), {});
    assert.strictEqual(r.ok, false);
    assert.strictEqual(r.code, 'PRESENCE_EVENT_TYPE_NOT_ALLOWED');
  });

  test('a non-string event type is rejected', () => {
    const r = validateEventBatch(body([ev(7)]), {});
    assert.strictEqual(r.ok, false);
    assert.strictEqual(r.code, 'PRESENCE_EVENT_TYPE_NOT_ALLOWED');
  });
});

describe('forbidden fields — rejected, never stripped', () => {
  // One test per key so a regression names the prohibited concept.
  for (const key of ['landmarks', 'score', 'emotion', 'confidence', 'attention', 'engagement']) {
    test(`'${key}' in an event is rejected 400 PRESENCE_FORBIDDEN_FIELD`, () => {
      const r = validateEventBatch(body([ev('face_absent', { [key]: 1 })]), {});
      assert.strictEqual(r.ok, false, `'${key}' must be a rejection, not an omission`);
      assert.strictEqual(r.status, 400);
      assert.strictEqual(r.code, 'PRESENCE_FORBIDDEN_FIELD');
      assert.strictEqual(r.field, key, 'the response must name the offending field');
      assert.ok(r.error.includes(key));
      assert.strictEqual(r.events, undefined, 'no events may be returned alongside a rejection');
    });

    test(`'${key}' at the top level is rejected 400 PRESENCE_FORBIDDEN_FIELD`, () => {
      const r = validateEventBatch(body([ev('face_absent')], { [key]: 'x' }), {});
      assert.strictEqual(r.ok, false);
      assert.strictEqual(r.status, 400);
      assert.strictEqual(r.code, 'PRESENCE_FORBIDDEN_FIELD');
      assert.strictEqual(r.field, key);
    });
  }

  test('a forbidden key nested two levels deep is caught', () => {
    const payload = {
      roomCode: 'ABCDEF',
      identity: 'cand-1',
      events: [ev('face_absent')],
      meta: { detector: { emotion: 'calm' } },
    };
    const r = validateEventBatch(payload, {});
    assert.strictEqual(r.ok, false);
    assert.strictEqual(r.code, 'PRESENCE_FORBIDDEN_FIELD');
    assert.strictEqual(r.field, 'emotion');
  });

  test('a forbidden key inside an array element is caught', () => {
    const payload = {
      roomCode: 'ABCDEF',
      identity: 'cand-1',
      events: [{ eventType: 'face_absent', startedAt: T0, endedAt: T1, durationMs: 1 }],
      samples: [{ ok: true }, { 'Gaze-Direction': 'left' }],
    };
    const r = validateEventBatch(payload, {});
    assert.strictEqual(r.ok, false);
    assert.strictEqual(r.code, 'PRESENCE_FORBIDDEN_FIELD');
    assert.strictEqual(r.field, 'Gaze-Direction');
  });

  test('forbidden beats unknown, so the error names the concept', () => {
    // 'meta' is also an unknown top-level key; the forbidden key inside it wins.
    const r = validateEventBatch({
      roomCode: 'ABCDEF', identity: 'cand-1', events: [ev('face_absent')],
      meta: { suspicion_score: 9 },
    }, {});
    assert.strictEqual(r.code, 'PRESENCE_FORBIDDEN_FIELD');
    assert.strictEqual(r.field, 'suspicion_score');
  });

  test('normalisation ignores case, underscores and hyphens', () => {
    assert.strictEqual(normaliseKey('Risk_Level'), 'risklevel');
    assert.strictEqual(normaliseKey('EYE-ASPECT-RATIO'), 'eyeaspectratio');
    for (const spelling of ['riskLevel', 'risk_level', 'RISK-LEVEL']) {
      const r = validateEventBatch(body([ev('face_absent', { [spelling]: 1 })]), {});
      assert.strictEqual(r.code, 'PRESENCE_FORBIDDEN_FIELD', spelling);
      assert.strictEqual(r.field, spelling);
    }
  });

  test('faceScore, face_score and FACE-SCORE all normalise to the same rejection', () => {
    // These normalise to the identical key, so they must all be refused
    // identically. The strict per-event allowlist is the control that refuses
    // them: ALLOWED_EVENT_KEYS has five entries and this is not one of them.
    const results = ['faceScore', 'face_score', 'FACE-SCORE'].map((spelling) =>
      validateEventBatch(body([ev('face_absent', { [spelling]: 0.9 })]), {}));
    for (const r of results) {
      assert.strictEqual(r.ok, false);
      assert.strictEqual(r.status, 400);
      assert.strictEqual(r.code, results[0].code);
    }
    assert.strictEqual(results[0].code, 'PRESENCE_UNKNOWN_FIELD');
  });

  test('head pose is not collected — yaw, pitch and roll are refused', () => {
    for (const key of ['yaw', 'pitch', 'roll', 'headPose']) {
      const r = validateEventBatch(body([ev('face_absent', { [key]: 12 })]), {});
      assert.strictEqual(r.code, 'PRESENCE_FORBIDDEN_FIELD', key);
      assert.strictEqual(r.field, key);
    }
  });

  test('no pixels ever — frame, image and landmarks are refused', () => {
    for (const key of ['frame', 'image', 'landmarks', 'thumbnail', 'base64']) {
      const r = validateEventBatch(body([ev('face_absent', { [key]: 'AAAA' })]), {});
      assert.strictEqual(r.code, 'PRESENCE_FORBIDDEN_FIELD', key);
      assert.strictEqual(r.field, key);
    }
  });

  test('every forbidden key is refused as an event field', () => {
    for (const key of FORBIDDEN_KEYS) {
      const r = validateEventBatch(body([ev('face_absent', { [key]: 1 })]), {});
      assert.strictEqual(r.code, 'PRESENCE_FORBIDDEN_FIELD', key);
    }
  });
});

describe('strict allowlist', () => {
  test('a client-supplied thresholds key is rejected — the server stamps thresholds', () => {
    const perEvent = validateEventBatch(body([ev('face_absent', { thresholds: { faceAbsentOpenMs: 1 } })]), {});
    assert.strictEqual(perEvent.ok, false);
    assert.strictEqual(perEvent.code, 'PRESENCE_UNKNOWN_FIELD');
    assert.strictEqual(perEvent.field, 'thresholds');

    const topLevel = validateEventBatch(body([ev('face_absent')], { thresholds: {} }), {});
    assert.strictEqual(topLevel.ok, false);
    assert.strictEqual(topLevel.code, 'PRESENCE_UNKNOWN_FIELD');
    assert.strictEqual(topLevel.field, 'thresholds');
  });

  test('an unknown event field is rejected', () => {
    const r = validateEventBatch(body([ev('face_absent', { sessionId: 'x' })]), {});
    assert.strictEqual(r.code, 'PRESENCE_UNKNOWN_FIELD');
    assert.strictEqual(r.field, 'sessionId');
  });

  test('detectorVersion is accepted for provenance but never echoed back as data', () => {
    const r = validateEventBatch(body([ev('face_absent', { detectorVersion: 'presence-1.0.0' })]), {});
    assert.strictEqual(r.ok, true);
    assert.strictEqual(r.events[0].detectorVersion, undefined,
      'the server stamps detector_version from the session row');
  });
});

describe('batch shape', () => {
  test('a well-formed batch of 100 is accepted', () => {
    const events = Array.from({ length: MAX_BATCH }, () => ev('face_absent'));
    const r = validateEventBatch(body(events), {});
    assert.strictEqual(r.ok, true);
    assert.strictEqual(r.events.length, 100);
  });

  test('101 events is 413 PRESENCE_BATCH_TOO_LARGE', () => {
    const events = Array.from({ length: MAX_BATCH + 1 }, () => ev('face_absent'));
    const r = validateEventBatch(body(events), {});
    assert.strictEqual(r.ok, false);
    assert.strictEqual(r.status, 413);
    assert.strictEqual(r.code, 'PRESENCE_BATCH_TOO_LARGE');
  });

  test('an empty batch is a valid heartbeat', () => {
    const r = validateEventBatch(body([]), {});
    assert.strictEqual(r.ok, true);
    assert.deepStrictEqual(r.events, []);
  });

  test('a non-object body, a missing roomCode/identity and a non-array events are refused', () => {
    assert.strictEqual(validateEventBatch(null, {}).code, 'PRESENCE_PAYLOAD_INVALID');
    assert.strictEqual(validateEventBatch([], {}).code, 'PRESENCE_PAYLOAD_INVALID');
    assert.strictEqual(validateEventBatch({ identity: 'c', events: [] }, {}).field, 'roomCode');
    assert.strictEqual(validateEventBatch({ roomCode: 'ABCDEF', events: [] }, {}).field, 'identity');
    assert.strictEqual(validateEventBatch({ roomCode: 'ABCDEF', identity: 'c', events: {} }, {}).field, 'events');
    assert.strictEqual(validateEventBatch(body(['nope']), {}).code, 'PRESENCE_PAYLOAD_INVALID');
  });

  test('an over-long identity is refused (the column is VARCHAR(128))', () => {
    const r = validateEventBatch({ roomCode: 'ABCDEF', identity: 'x'.repeat(129), events: [] }, {});
    assert.strictEqual(r.ok, false);
    assert.strictEqual(r.field, 'identity');
  });
});

describe('multiple_faces gate', () => {
  test('rejected 409 PRESENCE_EVENT_TYPE_DISABLED when the gate is off', () => {
    const r = validateEventBatch(body([ev('multiple_faces')]), { multipleFacesEnabled: false });
    assert.strictEqual(r.ok, false);
    assert.strictEqual(r.status, 409);
    assert.strictEqual(r.code, 'PRESENCE_EVENT_TYPE_DISABLED');
  });

  test('off is the default when the option is absent', () => {
    const r = validateEventBatch(body([ev('multiple_faces')]));
    assert.strictEqual(r.code, 'PRESENCE_EVENT_TYPE_DISABLED');
  });

  test('accepted when the gate is on', () => {
    const r = validateEventBatch(body([ev('multiple_faces')]), { multipleFacesEnabled: true });
    assert.strictEqual(r.ok, true);
    assert.strictEqual(r.events[0].eventType, 'multiple_faces');
  });

  test('the gate does not affect the other types', () => {
    const r = validateEventBatch(body([ev('face_absent')]), { multipleFacesEnabled: false });
    assert.strictEqual(r.ok, true);
  });
});

describe('timestamps and durations', () => {
  test('durationMs must be a non-negative integer', () => {
    assert.strictEqual(validateEventBatch(body([ev('face_absent', { durationMs: -1 })]), {}).field, 'durationMs');
    assert.strictEqual(validateEventBatch(body([ev('face_absent', { durationMs: 1.5 })]), {}).field, 'durationMs');
    assert.strictEqual(validateEventBatch(body([ev('face_absent', { durationMs: '12000' })]), {}).field, 'durationMs');
    assert.strictEqual(validateEventBatch(body([ev('face_absent', { durationMs: 0 })]), {}).ok, true);
  });

  test('durationMs is derived from the interval when omitted', () => {
    const r = validateEventBatch(body([{ eventType: 'face_absent', startedAt: T0, endedAt: T1 }]), {});
    assert.strictEqual(r.ok, true);
    assert.strictEqual(r.events[0].durationMs, 12000);
  });

  test('endedAt must not precede startedAt', () => {
    const r = validateEventBatch(body([{ eventType: 'face_absent', startedAt: T1, endedAt: T0 }]), {});
    assert.strictEqual(r.ok, false);
    assert.strictEqual(r.code, 'PRESENCE_PAYLOAD_INVALID');
    assert.strictEqual(r.field, 'endedAt');
  });

  test('an instantaneous event may omit endedAt — it ends where it starts', () => {
    const r = validateEventBatch(body([{ eventType: 'camera_disabled', startedAt: T0 }]), {});
    assert.strictEqual(r.ok, true);
    assert.strictEqual(r.events[0].endedAt, T0);
    assert.strictEqual(r.events[0].durationMs, 0);
  });

  test('timestamps must be ISO-8601 strings — an epoch number is ambiguous and refused', () => {
    assert.strictEqual(validateEventBatch(body([{ eventType: 'face_absent', startedAt: 1793000000 }]), {}).field, 'startedAt');
    assert.strictEqual(validateEventBatch(body([{ eventType: 'face_absent', startedAt: 'yesterday' }]), {}).field, 'startedAt');
    assert.strictEqual(validateEventBatch(body([{ eventType: 'face_absent', startedAt: '' }]), {}).field, 'startedAt');
  });

  test('timestamps are normalised to UTC ISO-8601', () => {
    const r = validateEventBatch(body([{ eventType: 'face_absent', startedAt: '2026-10-31T10:00:00+05:30' }]), {});
    assert.strictEqual(r.ok, true);
    assert.strictEqual(r.events[0].startedAt, '2026-10-31T04:30:00.000Z');
  });
});
