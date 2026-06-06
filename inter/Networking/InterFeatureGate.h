// ============================================================================
// InterFeatureGate.h — Centralized tier-based feature gating
//
// SINGLE SOURCE OF TRUTH for which features require which tier.
//
// To add a new gated feature:
//   1. Add an entry to the InterFeature enum below.
//   2. Add matching entries to the three lookup tables in InterFeatureGate.m.
//   3. Call [InterFeatureGate isFeature:InterFeatureYourFeature availableForTier:currentTier]
//      before executing the gated action. That's it — no other changes needed.
//
// Tier hierarchy (lowest → highest):
//   free (0) → pro (1) → pro+ (2) → hiring (3)
//
// The server enforces the same hierarchy via auth.requireTier() middleware,
// so client gating is UX only — users cannot bypass it via the network.
// ============================================================================

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// ---------------------------------------------------------------------------
// Feature registry
// ---------------------------------------------------------------------------

typedef NS_ENUM(NSUInteger, InterFeature) {
    /// Interview mode: secure window, screen monitoring, interviewee lock-in.
    /// Minimum tier: pro
    InterFeatureHostInterview = 0,

    /// Cloud (Egress) recording — server-side, downloadable after the call.
    /// Local recording remains available to all tiers.
    /// Minimum tier: pro
    InterFeatureCloudRecording,

    /// Scheduled meetings — create, invite, and start pre-scheduled sessions.
    /// Minimum tier: pro
    InterFeatureScheduledMeetings,

    /// Chat transcript export — host/co-host can save the chat log.
    /// Minimum tier: pro
    InterFeatureChatExport,

    // ── Add future features below this line ──────────────────────────────
    // Example:
    //   InterFeatureAITranscription,   // pro
    //   InterFeatureLiveCoding,        // hiring
};

// ---------------------------------------------------------------------------
// InterFeatureGate
// ---------------------------------------------------------------------------

@interface InterFeatureGate : NSObject

/// Returns YES if the feature is available at the given tier.
/// @param feature  The feature to check.
/// @param tier     The user's current effective tier (@"free", @"pro", @"pro+", @"hiring").
///                 Pass nil to treat as @"free".
+ (BOOL)isFeature:(InterFeature)feature availableForTier:(nullable NSString *)tier;

/// Returns the minimum tier name required for the feature (e.g. @"pro").
/// Used for display in upsell alerts.
+ (NSString *)minimumTierForFeature:(InterFeature)feature;

/// Returns a human-readable feature name (e.g. @"Interview Mode").
/// Used as the title in upsell alerts.
+ (NSString *)displayNameForFeature:(InterFeature)feature;

@end

NS_ASSUME_NONNULL_END
