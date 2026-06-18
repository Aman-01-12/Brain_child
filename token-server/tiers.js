// ============================================================================
// tiers.js — SINGLE SOURCE OF TRUTH for the server's tier hierarchy + feature
// gating. Mirrors the client's InterFeatureGate so the two cannot drift.
//
// Tiers (lowest → highest): free < pro < hiring.  (There is no "pro+".)
// `hiring` is the hiring-specialized top tier and inherits everything pro/free
// have. To change which tier a feature needs, edit FEATURE_MIN_TIER in ONE
// place here (and the matching one-line entry in InterFeatureGate.m).
//
// Pure + dependency-free so it is trivially unit-testable.
// ============================================================================

/// Ordered tier ranks. Higher rank = more access. Unknown tier → treated as free.
const TIER_RANKS = Object.freeze({
  free:   0,
  pro:    1,
  hiring: 2,
});

/// Stable feature identifiers (server-side mirror of InterFeature).
const FEATURES = Object.freeze({
  HOST_INTERVIEW:      'hostInterview',
  CLOUD_RECORDING:     'cloudRecording',
  SCHEDULED_MEETINGS:  'scheduledMeetings',
  CHAT_EXPORT:         'chatExport',
  COLLAB_CODE_EDITOR:  'collabCodeEditor',
  COLLAB_WHITEBOARD:   'collabWhiteboard',
});

/// Feature → minimum tier. THE place to change a cap. Interview + its in-call
/// tools require `hiring`; general premium features require `pro`.
const FEATURE_MIN_TIER = Object.freeze({
  [FEATURES.HOST_INTERVIEW]:     'hiring',
  [FEATURES.COLLAB_CODE_EDITOR]: 'hiring',
  [FEATURES.COLLAB_WHITEBOARD]:  'hiring',
  [FEATURES.CLOUD_RECORDING]:    'pro',
  [FEATURES.SCHEDULED_MEETINGS]: 'pro',
  [FEATURES.CHAT_EXPORT]:        'pro',
});

/// Numeric rank for a tier string. Unknown/missing → 0 (free) — fail safe.
function rankOf(tier) {
  return Object.prototype.hasOwnProperty.call(TIER_RANKS, tier) ? TIER_RANKS[tier] : 0;
}

/// True iff `tier` is at least `minTier`.
function tierMeets(tier, minTier) {
  return rankOf(tier) >= rankOf(minTier);
}

/// True iff `tier` may use `feature`. Unknown feature → false (fail closed).
function isFeatureAllowed(tier, feature) {
  const min = FEATURE_MIN_TIER[feature];
  if (min == null) return false;
  return tierMeets(tier, min);
}

/// Minimum tier name required for a feature, or null for an unknown feature.
function minTierForFeature(feature) {
  return FEATURE_MIN_TIER[feature] ?? null;
}

module.exports = {
  TIER_RANKS,
  FEATURES,
  FEATURE_MIN_TIER,
  rankOf,
  tierMeets,
  isFeatureAllowed,
  minTierForFeature,
};
