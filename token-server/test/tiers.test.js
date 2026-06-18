// ============================================================================
// tiers — unit tests (node:test) for the centralized tier/feature gate.
// ============================================================================

const { test } = require('node:test');
const assert = require('node:assert');
const tiers = require('../tiers');

test('tier model is exactly free < pro < hiring (no pro+)', () => {
  assert.deepStrictEqual(Object.keys(tiers.TIER_RANKS).sort(), ['free', 'hiring', 'pro']);
  assert.strictEqual(tiers.rankOf('free'), 0);
  assert.strictEqual(tiers.rankOf('pro'), 1);
  assert.strictEqual(tiers.rankOf('hiring'), 2);
  // pro+ is not a tier — treated as free (fail safe).
  assert.strictEqual(tiers.rankOf('pro+'), 0);
  assert.strictEqual(tiers.rankOf(undefined), 0);
  assert.strictEqual(tiers.rankOf('garbage'), 0);
});

test('tierMeets respects the hierarchy', () => {
  assert.strictEqual(tiers.tierMeets('hiring', 'pro'), true);
  assert.strictEqual(tiers.tierMeets('pro', 'pro'), true);
  assert.strictEqual(tiers.tierMeets('free', 'pro'), false);
  assert.strictEqual(tiers.tierMeets('pro', 'hiring'), false);
  assert.strictEqual(tiers.tierMeets('hiring', 'hiring'), true);
});

test('interview + its tools require hiring; hiring inherits pro features', () => {
  const F = tiers.FEATURES;
  // hiring-only features
  for (const f of [F.HOST_INTERVIEW, F.COLLAB_CODE_EDITOR, F.COLLAB_WHITEBOARD]) {
    assert.strictEqual(tiers.isFeatureAllowed('free', f), false, `${f} blocked for free`);
    assert.strictEqual(tiers.isFeatureAllowed('pro', f), false, `${f} blocked for pro`);
    assert.strictEqual(tiers.isFeatureAllowed('hiring', f), true, `${f} allowed for hiring`);
    assert.strictEqual(tiers.minTierForFeature(f), 'hiring');
  }
  // pro features — hiring inherits them
  for (const f of [F.CLOUD_RECORDING, F.SCHEDULED_MEETINGS, F.CHAT_EXPORT]) {
    assert.strictEqual(tiers.isFeatureAllowed('free', f), false, `${f} blocked for free`);
    assert.strictEqual(tiers.isFeatureAllowed('pro', f), true, `${f} allowed for pro`);
    assert.strictEqual(tiers.isFeatureAllowed('hiring', f), true, `${f} allowed for hiring (inherits)`);
    assert.strictEqual(tiers.minTierForFeature(f), 'pro');
  }
});

test('unknown feature fails closed', () => {
  assert.strictEqual(tiers.isFeatureAllowed('hiring', 'nonexistentFeature'), false);
  assert.strictEqual(tiers.minTierForFeature('nonexistentFeature'), null);
});

test('a pro+ string never gains hiring access (no pro+ tier exists)', () => {
  // Guards the bug class we are fixing: a stray "pro+" must NOT be treated as
  // a real tier that could unlock hiring/pro features.
  assert.strictEqual(tiers.isFeatureAllowed('pro+', tiers.FEATURES.HOST_INTERVIEW), false);
  assert.strictEqual(tiers.isFeatureAllowed('pro+', tiers.FEATURES.CLOUD_RECORDING), false);
});
