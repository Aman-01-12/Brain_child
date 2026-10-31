// ============================================================================
// presenceConfig.js — PRESENCE MONITORING (provisional)
//
// Configuration + the pure arming predicate for candidate presence monitoring
// in secure interview mode. See .agents/tasks/presence-monitoring/plan.md and
// .agents/tasks/presence-monitoring/REMOVAL.md.
//
// This feature is PROVISIONAL and EVALUATION-FIRST. It ships behind ONE master
// flag, PRESENCE_MONITORING_ENABLED, which defaults to FALSE. When it is off the
// server never writes `presenceMonitoringArmed` into the room hash, so
// /room/join omits the whole presence block and the client parses `armed:false`
// by its backward-compatible default — i.e. identical to talking to a server
// that never had this feature.
//
// There are exactly TWO places that consult the master flag, both in new files:
//   1. requirePresenceFeature, the /presence router's first middleware (presence.js)
//   2. resolvePresenceArming() below, called from /room/create
//
// Every getter reads process.env AT CALL TIME, never at module load, so tests
// (and an operator restarting with a changed .env) see the current value and no
// module-reload dance is needed.
//
// Pure: no I/O, no DB, no Redis. The only dependency is tiers.js, which is
// itself pure, so the hiring-tier rule has exactly one source of truth.
// ============================================================================

const tiers = require('./tiers');

/// The detector operating-point identifier stamped onto every session and event
/// row. Bump this when the detector's behaviour changes: a stored event is a fact
/// about a moment under a stated operating point, so old rows keep the version
/// they were recorded under and are never recomputed.
const DETECTOR_VERSION = 'presence-1.0.0';

/// Which notice text the candidate was shown. Pinned onto the session row.
const CONSENT_VERSION = 'presence-2026-10-31';

// ---------------------------------------------------------------------------
// Env getters — all read at call time
// ---------------------------------------------------------------------------

/// THE master flag. Default false: the feature is off unless an operator opts in.
function isFeatureEnabled() {
  return process.env.PRESENCE_MONITORING_ENABLED === 'true';
}

/// Retention window for session + event rows, in days. Default 90, clamped to
/// 1…3650. Anything unparseable, zero or negative falls back to 90 rather than
/// to "keep forever" or "delete immediately" — both of which are worse failures.
function retentionDays() {
  const raw = Number(process.env.PRESENCE_EVENT_RETENTION_DAYS);
  if (!Number.isFinite(raw) || raw <= 0) return 90;
  return Math.min(Math.floor(raw), 3650);
}

/// The multiple_faces signal gate. Default FALSE in production: it must not be
/// enabled until the false-positive study passes (>= 20 sessions, varied
/// lighting / rooms / webcams / skin tones, per-session FP rate under 5% for
/// this event type). That study needs real humans in real rooms.
function multipleFacesEnabled() {
  return process.env.PRESENCE_MULTIPLE_FACES_ENABLED === 'true';
}

/// How long client silence must last before the SERVER records a monitoring_gap.
/// Gaps exist so silence is visible rather than indistinguishable from a clean
/// session; a client can neither forge nor suppress them. Default 60 s.
function gapSeconds() {
  const raw = Number(process.env.PRESENCE_GAP_SECONDS);
  if (!Number.isFinite(raw) || raw <= 0) return 60;
  return Math.floor(raw);
}

/// Retention sweeper cadence in ms. Default 1 hour.
function sweepIntervalMs() {
  const raw = Number(process.env.PRESENCE_SWEEP_INTERVAL_MS);
  if (!Number.isFinite(raw) || raw <= 0) return 3600000;
  return Math.floor(raw);
}

/// How long a live session may go unreported before the sweeper closes it with a
/// terminal monitoring_gap. Default 10 minutes.
function staleSessionMinutes() {
  const raw = Number(process.env.PRESENCE_STALE_SESSION_MINUTES);
  if (!Number.isFinite(raw) || raw <= 0) return 10;
  return Math.floor(raw);
}

/// The address the consent screen shows for a copy/erasure request. The
/// candidate-facing rights endpoint is DEFERRED, so until it exists requests are
/// handled manually by the operator at this address.
function rightsContact() {
  const raw = process.env.PRESENCE_RIGHTS_CONTACT;
  return (typeof raw === 'string' && raw.trim().length > 0)
    ? raw.trim()
    : 'privacy@kiomeet.invalid';
}

// ---------------------------------------------------------------------------
// thresholdSnapshot — the operating point written onto every row
// ---------------------------------------------------------------------------

/// The thresholds in force, stamped by the SERVER onto the session row at
/// consent time and copied onto every event row from the session. A client never
/// supplies these: it cannot rewrite the operating point of its own record.
/// Changing a threshold later produces new rows going forward and never
/// different rows looking back — no retroactive recomputation, ever.
///
/// Durations are milliseconds. "open" = how long the condition must hold
/// continuously before an event opens; "close" = how long it must have cleared
/// before the event closes.
function thresholdSnapshot() {
  return Object.freeze({
    sampleIntervalMs:      500,    // 2 Hz
    faceAbsentOpenMs:      10000,
    multipleFacesOpenMs:   3000,
    imageQualityOpenMs:    15000,
    closeMs:               1000,
    // The FACE DETECTOR's own confidence in a bounding box, and the box's share
    // of the frame. Below either floor the honest record is
    // image_quality_insufficient — a fact about the VIDEO. Neither value is, or
    // may ever become, an inference about the candidate: detection failure rates
    // are not uniform across skin tones, lighting or webcam quality, and
    // attributing a failure to the person turns an equipment inequality into an
    // accusation.
    detectorConfidenceFloor: 0.35,
    minBoxAreaFraction:      0.01,
    gapSeconds:              gapSeconds(),
  });
}

// ---------------------------------------------------------------------------
// resolvePresenceArming — the pure arming predicate
// ---------------------------------------------------------------------------

/// Decide whether a room being created arms presence monitoring.
///
/// Returns { armed, reason } where reason is one of:
///   'feature_disabled' | 'not_interview' | 'tier' | 'eu_region' | 'under_18'
///   | 'not_requested' | 'armed'
///
/// `armed` is true only when every condition passes. Fail closed on anything
/// unexpected: an unknown host tier ranks as free and therefore does not arm.
///
/// WARNING — EU residency forces armed = false, and this is not a footnote.
/// The EU AI Act Art. 5(1)(f) makes inferring emotion from biometric data in a
/// hiring context a PROHIBITED practice (applicable since 2 Feb 2025, up to
/// EUR 35M / 7% of worldwide turnover), and this product would be bound as
/// provider. This feature infers NO emotion, affect, attention or engagement by
/// design — but its Art. 6(3) classification against the adjacent prohibition is
/// unresolved pending legal review, so the honest default for an EU-resident
/// candidate is monitoring off. Research memo section 7.9 item 7.
///
/// Under-18 candidates are likewise never offered the monitored path: a minor's
/// consent in an employment-power-asymmetry setting is not a sound legal basis.
/// Research memo section 7.9 item 8.
function resolvePresenceArming({
  featureEnabled,
  roomType,
  hostTier,
  requested,
  candidateRegionEU,
  candidateUnder18,
} = {}) {
  if (featureEnabled !== true) return { armed: false, reason: 'feature_disabled' };
  if (roomType !== 'interview') return { armed: false, reason: 'not_interview' };
  if (!tiers.isFeatureAllowed(hostTier, tiers.FEATURES.HOST_INTERVIEW)) {
    return { armed: false, reason: 'tier' };
  }
  // See the WARNING above — these two are load-bearing, not conveniences.
  if (candidateRegionEU === true) return { armed: false, reason: 'eu_region' };
  if (candidateUnder18 === true) return { armed: false, reason: 'under_18' };
  if (requested !== true) return { armed: false, reason: 'not_requested' };
  return { armed: true, reason: 'armed' };
}

module.exports = {
  DETECTOR_VERSION,
  CONSENT_VERSION,
  isFeatureEnabled,
  retentionDays,
  multipleFacesEnabled,
  gapSeconds,
  sweepIntervalMs,
  staleSessionMinutes,
  rightsContact,
  thresholdSnapshot,
  resolvePresenceArming,
};
