// ============================================================================
// presenceRetention — unit tests (node:test). PRESENCE MONITORING (provisional)
//
// The retention sweeper with injected fakes (the recordingQuota.test.js style).
// No live DB, no Redis.
//
// The fake db models the two predicates that make the sweeper idempotent —
// `purge_after <= NOW()` and `ended_at IS NULL` — as flags on fake rows, and the
// tests additionally assert that the real SQL carries those predicates. Both
// halves matter: the flags prove the behaviour, the text assertions prove the
// behaviour is guarded in the database and not just in the fake.
// ============================================================================

const { test, describe } = require('node:test');
const assert = require('node:assert');
const { createPresenceSweeper } = require('./../presenceRetention');
const presenceConfig = require('./../presenceConfig');

const silentLogger = { log() {}, error() {} };

const fixedConfig = {
  retentionDays: () => 90,
  staleSessionMinutes: () => 10,
};

/// A fake pg client. `due: true` stands for "purge_after <= NOW()" and
/// `stale: true` for "last_report_at older than the stale window".
function makeFakeDb({ events = [], sessions = [] } = {}) {
  const calls = [];
  const state = {
    events: events.map((e) => ({ ...e })),
    sessions: sessions.map((s) => ({ ...s })),
    gapInserts: [],
  };

  const db = {
    async query(text, params) {
      calls.push({ text, params });

      if (/^\s*DELETE FROM interview_presence_events/.test(text)) {
        const due = state.events.filter((e) => e.due === true);
        state.events = state.events.filter((e) => e.due !== true);
        return { rowCount: due.length, rows: [] };
      }
      if (/^\s*DELETE FROM interview_presence_sessions/.test(text)) {
        const due = state.sessions.filter((s) => s.due === true);
        state.sessions = state.sessions.filter((s) => s.due !== true);
        return { rowCount: due.length, rows: [] };
      }
      if (/SELECT id, last_report_at/.test(text)) {
        const stale = state.sessions.filter(
          (s) => s.monitoring_enabled === true && s.ended_at == null && s.stale === true
        );
        return { rowCount: stale.length, rows: stale.map((s) => ({ ...s })) };
      }
      if (/INSERT INTO interview_presence_events/.test(text)) {
        state.gapInserts.push(params);
        return { rowCount: 1, rows: [] };
      }
      if (/UPDATE interview_presence_sessions/.test(text)) {
        const row = state.sessions.find((s) => s.id === params[0] && s.ended_at == null);
        if (!row) return { rowCount: 0, rows: [] };
        row.ended_at = new Date().toISOString();
        return { rowCount: 1, rows: [] };
      }
      throw new Error(`unexpected query: ${text.slice(0, 60)}`);
    },
  };

  return { db, calls, state };
}

function makeAuditSpy() {
  const calls = [];
  return { spy: (...args) => calls.push(args), calls };
}

describe('purging due rows', () => {
  test('due rows are purged and the sweeper reports their count', async () => {
    const { db, state } = makeFakeDb({
      events: [{ id: 1, due: true }, { id: 2, due: true }, { id: 3, due: false }],
      sessions: [{ id: 's1', due: true }, { id: 's2', due: false }],
    });
    const { spy, calls } = makeAuditSpy();
    const sweep = createPresenceSweeper({ db, auditLog: spy, config: fixedConfig, logger: silentLogger });

    const result = await sweep();
    assert.deepStrictEqual(result, { eventRows: 2, sessionRows: 1, staleClosed: 0 });
    assert.deepStrictEqual(state.events.map((e) => e.id), [3], 'the not-yet-due event survives');
    assert.deepStrictEqual(state.sessions.map((s) => s.id), ['s2'], 'the not-yet-due session survives');
    assert.strictEqual(calls.length, 1);
  });

  test('both DELETE statements are guarded by purge_after <= NOW()', async () => {
    const { db, calls } = makeFakeDb();
    const sweep = createPresenceSweeper({ db, auditLog: () => {}, config: fixedConfig, logger: silentLogger });
    await sweep();
    const deletes = calls.filter((c) => /^\s*DELETE FROM/.test(c.text));
    assert.strictEqual(deletes.length, 2);
    for (const d of deletes) {
      assert.match(d.text, /purge_after <= NOW\(\)/,
        'an unguarded DELETE would destroy rows that are still inside their retention window');
    }
  });

  test('a second sweep over already-swept state returns zeros — idempotent', async () => {
    const { db } = makeFakeDb({
      events: [{ id: 1, due: true }],
      sessions: [{ id: 's1', due: true }],
    });
    const sweep = createPresenceSweeper({ db, auditLog: () => {}, config: fixedConfig, logger: silentLogger });
    const first = await sweep();
    const second = await sweep();
    assert.deepStrictEqual(first, { eventRows: 1, sessionRows: 1, staleClosed: 0 });
    assert.deepStrictEqual(second, { eventRows: 0, sessionRows: 0, staleClosed: 0 });
  });
});

describe('closing stale sessions', () => {
  test('exactly one monitoring_gap per stale session, then ended_at is set', async () => {
    const { db, state, calls } = makeFakeDb({
      sessions: [
        { id: 's1', monitoring_enabled: true, ended_at: null, stale: true, last_report_at: '2026-10-31T10:00:00Z' },
        { id: 's2', monitoring_enabled: true, ended_at: null, stale: true, last_report_at: '2026-10-31T10:05:00Z' },
        { id: 's3', monitoring_enabled: true, ended_at: null, stale: false, last_report_at: '2026-10-31T11:59:00Z' },
        { id: 's4', monitoring_enabled: false, ended_at: null, stale: true, last_report_at: '2026-10-31T09:00:00Z' },
      ],
    });
    const sweep = createPresenceSweeper({ db, auditLog: () => {}, config: fixedConfig, logger: silentLogger });

    const result = await sweep();
    assert.strictEqual(result.staleClosed, 2, 'only the live, stale, monitoring-enabled sessions are closed');
    assert.strictEqual(state.gapInserts.length, 2, 'one gap per stale session, not two');
    assert.strictEqual(state.sessions.find((s) => s.id === 's1').ended_at != null, true);
    assert.strictEqual(state.sessions.find((s) => s.id === 's3').ended_at, null);
    assert.strictEqual(state.sessions.find((s) => s.id === 's4').ended_at, null);

    const insert = calls.find((c) => /INSERT INTO interview_presence_events/.test(c.text));
    assert.match(insert.text, /'monitoring_gap'/, 'the gap event type is server-chosen');
    assert.match(insert.text, /'server'/, 'a gap is always source=server — a client cannot forge one');
    assert.match(insert.text, /s\.detector_version, s\.thresholds/,
      'the operating point is copied from the session row, never from a client');

    const select = calls.find((c) => /SELECT id, last_report_at/.test(c.text));
    assert.match(select.text, /ended_at IS NULL/);
    assert.match(select.text, /monitoring_enabled = TRUE/);
  });

  test('a second run closes nothing — the ended_at IS NULL guard no longer matches', async () => {
    const { db, state } = makeFakeDb({
      sessions: [
        { id: 's1', monitoring_enabled: true, ended_at: null, stale: true, last_report_at: '2026-10-31T10:00:00Z' },
      ],
    });
    const sweep = createPresenceSweeper({ db, auditLog: () => {}, config: fixedConfig, logger: silentLogger });
    const first = await sweep();
    const second = await sweep();
    assert.strictEqual(first.staleClosed, 1);
    assert.strictEqual(second.staleClosed, 0);
    assert.strictEqual(state.gapInserts.length, 1, 'no second gap for the same silence');
  });

  test('the gap duration is derived in SQL from the session clock', async () => {
    const { db, calls } = makeFakeDb({
      sessions: [
        { id: 's1', monitoring_enabled: true, ended_at: null, stale: true, last_report_at: '2026-10-31T10:00:00Z' },
      ],
    });
    const sweep = createPresenceSweeper({ db, auditLog: () => {}, config: fixedConfig, logger: silentLogger });
    await sweep();
    const insert = calls.find((c) => /INSERT INTO interview_presence_events/.test(c.text));
    assert.match(insert.text, /s\.last_report_at, NOW\(\)/);
    assert.match(insert.text, /GREATEST\(0,/, 'a clock skew must never produce a negative duration');
  });
});

describe('failure handling', () => {
  test('a db.query rejection is caught and does not escape sweepOnce', async () => {
    const logged = [];
    const db = { async query() { throw new Error('connection terminated'); } };
    const sweep = createPresenceSweeper({
      db, auditLog: () => {}, config: fixedConfig,
      logger: { log() {}, error: (m) => logged.push(m) },
    });

    const result = await sweep();
    assert.deepStrictEqual(result, { eventRows: 0, sessionRows: 0, staleClosed: 0 });
    assert.strictEqual(logged.length, 3, 'each phase logs its own failure');
    for (const line of logged) assert.match(line, /connection terminated/);
  });

  test('a failure closing one stale session does not abandon the others', async () => {
    const { db } = makeFakeDb({
      sessions: [
        { id: 's1', monitoring_enabled: true, ended_at: null, stale: true, last_report_at: '2026-10-31T10:00:00Z' },
        { id: 's2', monitoring_enabled: true, ended_at: null, stale: true, last_report_at: '2026-10-31T10:00:00Z' },
      ],
    });
    const wrapped = {
      async query(text, params) {
        if (/INSERT INTO interview_presence_events/.test(text) && params[0] === 's1') {
          throw new Error('deadlock detected');
        }
        return db.query(text, params);
      },
    };
    const sweep = createPresenceSweeper({ db: wrapped, auditLog: () => {}, config: fixedConfig, logger: silentLogger });
    const result = await sweep();
    assert.strictEqual(result.staleClosed, 1, 's2 is still closed despite s1 failing');
  });
});

describe('audit trail', () => {
  test('presence_events_purged is written exactly once when rows were deleted', async () => {
    const { db } = makeFakeDb({ events: [{ id: 1, due: true }], sessions: [] });
    const { spy, calls } = makeAuditSpy();
    const sweep = createPresenceSweeper({ db, auditLog: spy, config: fixedConfig, logger: silentLogger });

    await sweep();
    assert.strictEqual(calls.length, 1);
    const [userId, eventType, ip, metadata] = calls[0];
    assert.strictEqual(userId, null, 'the sweeper acts on nobody’s behalf');
    assert.strictEqual(eventType, 'presence_events_purged');
    assert.ok(eventType.length <= 50, 'audit_events.event_type is VARCHAR(50)');
    assert.strictEqual(ip, null);
    assert.deepStrictEqual(metadata, { eventRows: 1, sessionRows: 0, retentionDays: 90 });
  });

  test('nothing is audited when nothing was deleted', async () => {
    const { db } = makeFakeDb({
      events: [{ id: 1, due: false }],
      sessions: [
        { id: 's1', monitoring_enabled: true, ended_at: null, stale: true, last_report_at: '2026-10-31T10:00:00Z' },
      ],
    });
    const { spy, calls } = makeAuditSpy();
    const sweep = createPresenceSweeper({ db, auditLog: spy, config: fixedConfig, logger: silentLogger });

    const result = await sweep();
    assert.strictEqual(result.staleClosed, 1, 'a closed session is not a deletion');
    assert.strictEqual(calls.length, 0, 'an audit row per idle tick would bury the ones that mean something');
  });
});

describe('retentionDays env handling', () => {
  const original = process.env.PRESENCE_EVENT_RETENTION_DAYS;
  function withEnv(value, fn) {
    if (value === undefined) delete process.env.PRESENCE_EVENT_RETENTION_DAYS;
    else process.env.PRESENCE_EVENT_RETENTION_DAYS = value;
    try { fn(); } finally {
      if (original === undefined) delete process.env.PRESENCE_EVENT_RETENTION_DAYS;
      else process.env.PRESENCE_EVENT_RETENTION_DAYS = original;
    }
  }

  test('honours a valid value', () => {
    withEnv('30', () => assert.strictEqual(presenceConfig.retentionDays(), 30));
  });

  test('falls back to 90 for unset, zero, garbage and negative values', () => {
    withEnv(undefined, () => assert.strictEqual(presenceConfig.retentionDays(), 90));
    withEnv('0', () => assert.strictEqual(presenceConfig.retentionDays(), 90));
    withEnv('abc', () => assert.strictEqual(presenceConfig.retentionDays(), 90));
    withEnv('-7', () => assert.strictEqual(presenceConfig.retentionDays(), 90));
    withEnv('', () => assert.strictEqual(presenceConfig.retentionDays(), 90));
  });

  test('clamps an absurd value to ten years', () => {
    withEnv('99999', () => assert.strictEqual(presenceConfig.retentionDays(), 3650));
  });

  test('getters read the environment at call time, not at module load', () => {
    const before = presenceConfig.retentionDays();
    withEnv('45', () => assert.strictEqual(presenceConfig.retentionDays(), 45));
    assert.strictEqual(presenceConfig.retentionDays(), before);
  });
});

describe('resolvePresenceArming', () => {
  const armedInput = {
    featureEnabled: true,
    roomType: 'interview',
    hostTier: 'hiring',
    requested: true,
    candidateRegionEU: false,
    candidateUnder18: false,
  };

  test('arms only when every condition passes', () => {
    assert.deepStrictEqual(presenceConfig.resolvePresenceArming(armedInput), { armed: true, reason: 'armed' });
  });

  test('the master flag is the first thing that stops it', () => {
    const r = presenceConfig.resolvePresenceArming({ ...armedInput, featureEnabled: false });
    assert.deepStrictEqual(r, { armed: false, reason: 'feature_disabled' });
  });

  test('a plain call room never arms', () => {
    const r = presenceConfig.resolvePresenceArming({ ...armedInput, roomType: 'call' });
    assert.deepStrictEqual(r, { armed: false, reason: 'not_interview' });
  });

  test('a sub-hiring or unknown host tier never arms', () => {
    for (const tier of ['free', 'pro', undefined, 'enterprise']) {
      const r = presenceConfig.resolvePresenceArming({ ...armedInput, hostTier: tier });
      assert.deepStrictEqual(r, { armed: false, reason: 'tier' }, String(tier));
    }
  });

  test('an EU-resident candidate is never monitored', () => {
    const r = presenceConfig.resolvePresenceArming({ ...armedInput, candidateRegionEU: true });
    assert.deepStrictEqual(r, { armed: false, reason: 'eu_region' });
  });

  test('an under-18 candidate is never monitored', () => {
    const r = presenceConfig.resolvePresenceArming({ ...armedInput, candidateUnder18: true });
    assert.deepStrictEqual(r, { armed: false, reason: 'under_18' });
  });

  test('not asking for it means not armed', () => {
    const r = presenceConfig.resolvePresenceArming({ ...armedInput, requested: false });
    assert.deepStrictEqual(r, { armed: false, reason: 'not_requested' });
  });

  test('missing input fails closed', () => {
    assert.strictEqual(presenceConfig.resolvePresenceArming().armed, false);
    assert.strictEqual(presenceConfig.resolvePresenceArming({}).armed, false);
  });
});
