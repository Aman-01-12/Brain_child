// ============================================================================
// InterFeatureGate.m — Tier lookup tables
//
// To add a new gated feature:
//   1. Add entry to InterFeature enum in InterFeatureGate.h.
//   2. Add matching entries to sTierMinRank and sDisplayName below.
//      (sMinTierName is derived automatically from sTierMinRank — do not edit it.)
//   3. Call [InterFeatureGate isFeature:… availableForTier:…] at the action site.
// ============================================================================

#import "InterFeatureGate.h"

// ---------------------------------------------------------------------------
// Tier rank values — must match TIER_LEVELS in token-server/auth.js
// ---------------------------------------------------------------------------
static NSDictionary<NSString *, NSNumber *> *sTierRanks;

// ---------------------------------------------------------------------------
// Feature → minimum required tier rank
// To move a feature to a higher tier: change the @N here. One line.
// ---------------------------------------------------------------------------
static NSDictionary<NSNumber *, NSNumber *> *sTierMinRank;

// ---------------------------------------------------------------------------
// Feature → minimum tier display name (used in upsell alerts)
// ---------------------------------------------------------------------------
static NSDictionary<NSNumber *, NSString *> *sMinTierName;

// ---------------------------------------------------------------------------
// Feature → human-readable name (used in upsell alerts)
// ---------------------------------------------------------------------------
static NSDictionary<NSNumber *, NSString *> *sDisplayName;

@implementation InterFeatureGate

+ (void)initialize {
    if (self != [InterFeatureGate class]) return;

    sTierRanks = @{
        @"free":    @0,
        @"pro":     @1,
        @"pro+":    @2,
        @"hiring":  @3,
    };

    // ── Feature minimum tier ranks ─────────────────────────────────────────
    // Change @1 → @2 to require pro+, @3 to require hiring, etc.
    sTierMinRank = @{
        @(InterFeatureHostInterview):     @1,  // pro
        @(InterFeatureCloudRecording):    @1,  // pro
        @(InterFeatureScheduledMeetings): @1,  // pro
        @(InterFeatureChatExport):          @1,  // pro
    };

    // Derive sMinTierName from sTierMinRank so the two cannot drift.
    // Only this rank→name table needs updating when tiers are added/renamed.
    NSDictionary<NSNumber *, NSString *> *rankToName = @{
        @0: @"free",
        @1: @"pro",
        @2: @"pro+",
        @3: @"hiring",
    };
    NSMutableDictionary<NSNumber *, NSString *> *minTierName = [NSMutableDictionary dictionaryWithCapacity:sTierMinRank.count];
    for (NSNumber *featureKey in sTierMinRank) {
        minTierName[featureKey] = rankToName[sTierMinRank[featureKey]] ?: @"pro";
    }
    sMinTierName = [minTierName copy];

    sDisplayName = @{
        @(InterFeatureHostInterview):     @"Interview Mode",
        @(InterFeatureCloudRecording):    @"Cloud Recording",
        @(InterFeatureScheduledMeetings): @"Scheduled Meetings",
        @(InterFeatureChatExport):          @"Chat Export",
    };
}

+ (BOOL)isFeature:(InterFeature)feature availableForTier:(nullable NSString *)tier {
    NSNumber *minRankNum = sTierMinRank[@(feature)];
    if (!minRankNum) return NO;  // unknown feature → fail-closed
    NSInteger userRank = [sTierRanks[tier ?: @"free"] integerValue];
    return userRank >= minRankNum.integerValue;
}

+ (NSString *)minimumTierForFeature:(InterFeature)feature {
    return sMinTierName[@(feature)] ?: @"pro";
}

+ (NSString *)displayNameForFeature:(InterFeature)feature {
    return sDisplayName[@(feature)] ?: @"This feature";
}

@end
