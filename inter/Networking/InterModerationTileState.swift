// ============================================================================
// InterModerationTileState.swift
// inter
//
// Consent-first moderation — single source of truth for the host's per-tile
// view of a participant's mic state.
//
// See docs/superpowers/specs/2026-06-10-consent-first-moderation-design.md.
//
// WHY THIS EXISTS:
//   The host tile historically computed its status caption (real LiveKit state)
//   and its menu action (host intent) on SEPARATE code paths, so they could
//   drift apart or contradict each other (e.g. caption "Muted (mute-all)" shown
//   next to a "Mute Mic" button). This file derives BOTH the caption and the
//   single primary action from ONE cause, in one place, so they can never
//   disagree by construction. Every host-side per-participant surface (tile
//   caption, 3-dot menu) renders from `deriveMic(...)`.
//
// ISOLATION INVARIANT (matches InterPermissions.swift):
//   Pure data + logic. No UIKit/AppKit, no network, no side effects. Fully
//   enumerable and unit-tested (see interTests/InterModerationTileStateTests).
//
// SCOPE: PR #1 is microphone only. Camera mirrors this exactly in PR #2.
// ============================================================================

import Foundation

// MARK: - Mic Cause (drives the caption)

/// The single authoritative reason a participant's mic is in its current state,
/// as seen by the host. The status caption is a pure function of this value, and
/// so is the primary action — so the two can never contradict.
///
/// Precedence (highest first): host block → global mute-all → live → pending → self.
@objc public enum InterMicCause: Int, CaseIterable {
    /// The participant's mic is live (unmuted). The ONLY cause from which the
    /// host's primary action is "Mute" — so "Mute" never sits beside a muted caption.
    case micOn = 0
    /// The participant muted their own mic and is not otherwise restricted.
    case selfMuted = 1
    /// The host applied a per-tile block to this participant.
    case mutedByHost = 2
    /// A global Mute-All is in effect (no individual host block on this participant).
    case mutedByMuteAll = 3
    /// The host lifted their block (or the participant was invited) and the mic is
    /// still off, awaiting the participant's own tap. NOT a self-mute — labeling it
    /// "Self-muted" would assert agency the participant never exercised (Finding A).
    case offCanUnmute = 4
    /// Same as `offCanUnmute`, but an "Ask to Unmute" is currently pending/in-cooldown.
    case askedToUnmute = 5

    /// Host-facing caption shown on the tile. Default copy; final word-smithing is a
    /// UI-layer concern (spec §8) — callers may localize/override.
    public var captionText: String {
        switch self {
        case .micOn:         return "Mic on"
        case .selfMuted:     return "Self-muted"
        case .mutedByHost:   return "Muted by you"
        case .mutedByMuteAll: return "Muted (mute-all)"
        case .offCanUnmute:  return "Off — can unmute"
        case .askedToUnmute: return "Asked to unmute"
        }
    }

    /// Whether the participant's mic is actually off in this cause. (`micOn` is the
    /// only live cause.) Useful for asserting the no-contradiction invariant.
    public var isMuted: Bool { self != .micOn }
}

// MARK: - Primary Action (one cause-derived host action)

/// The single primary action the host can take from the 3-dot menu, derived from
/// the same cause as the caption. No host action ever force-activates a device in
/// normal mode — see `activationForcesDevice` for the interview-mode exception.
@objc public enum InterMicPrimaryAction: Int, CaseIterable {
    /// Apply a host block. Reachable ONLY from `micOn`, so it never contradicts a
    /// "Muted (…)" caption.
    case mute = 0
    /// Send the consent affordance (no force-on). Used when the participant is
    /// self-muted / off-can-unmute.
    case askToUnmute = 1
    /// Host-muted case only: one click lifts the host's block AND sends the consent
    /// affordance. Still does not force the mic on (normal mode) — a deliberate,
    /// scoped coupling of lift+ask justified because the host muted them.
    case removeMuteAndAsk = 2
    /// Mute-All case: grant a one-time speak slot (existing approve flow).
    case allowToSpeak = 3

    /// Default button title. Final word-smithing is a UI-layer concern (spec §8).
    public var title: String {
        switch self {
        case .mute:             return "Mute Mic"
        case .askToUnmute:      return "Ask to Unmute"
        case .removeMuteAndAsk: return "Remove Mute & Ask"
        case .allowToSpeak:     return "Allow to Speak"
        }
    }

    /// True for actions that aim to ACTIVATE the participant's mic (vs restrict it).
    /// Only these are force-executed in interview mode. `mute` is a restriction and
    /// is never a forced activation.
    public var isActivation: Bool {
        switch self {
        case .askToUnmute, .removeMuteAndAsk, .allowToSpeak: return true
        case .mute: return false
        }
    }
}

// MARK: - Secondary Action (optional)

/// An optional secondary menu item, shown only where the primary action would
/// otherwise drop a real capability.
@objc public enum InterMicSecondaryAction: Int, CaseIterable {
    case none = 0
    /// Enforce-mute someone who is already self/globally muted, so they cannot
    /// self-unmute. Choosing it transitions the cause to `mutedByHost`.
    case blockMic = 1

    /// Default button title, or nil when there is no secondary action.
    public var title: String? {
        switch self {
        case .none:     return nil
        case .blockMic: return "Block mic"
        }
    }
}

// MARK: - Derived Tile State (result)

/// The complete, derived host-facing state for one participant's mic. Caption and
/// actions are computed together from one cause, so they are always consistent.
@objc public final class InterMicTileState: NSObject {
    @objc public let cause: InterMicCause
    @objc public let primaryAction: InterMicPrimaryAction
    @objc public let secondaryAction: InterMicSecondaryAction
    /// True when the primary action will FORCE the device on (and therefore must show
    /// the participant a "host enabled your mic" indicator). False in normal mode;
    /// true only in interview mode for activation actions. Also flips the primary
    /// button label to a direct "Unmute" (see `primaryActionTitle`).
    @objc public let activationForcesDevice: Bool

    @objc public var captionText: String { cause.captionText }

    /// The primary button title. In interview mode an activation action force-turns the
    /// mic on, so it reads a direct **"Unmute"** rather than the consent-flow wording
    /// ("Ask to Unmute" / "Remove Mute & Ask" / "Allow to Speak"). `mute` and all
    /// normal-mode actions keep their own titles. (`activationForcesDevice` is exactly
    /// `interview && primaryAction.isActivation`.)
    @objc public var primaryActionTitle: String {
        activationForcesDevice ? "Unmute" : primaryAction.title
    }

    /// The secondary "Block mic" remains available in interview mode — interview is a
    /// superset of host control (the interviewer may force-activate AND block), so the
    /// enforce-block is never removed. (Derivation is mode-independent for the secondary.)
    @objc public var secondaryActionTitle: String? { secondaryAction.title }

    init(cause: InterMicCause,
         primaryAction: InterMicPrimaryAction,
         secondaryAction: InterMicSecondaryAction,
         activationForcesDevice: Bool) {
        self.cause = cause
        self.primaryAction = primaryAction
        self.secondaryAction = secondaryAction
        self.activationForcesDevice = activationForcesDevice
        super.init()
    }
}

// MARK: - Derivation

@objc public final class InterModerationTileState: NSObject {

    /// Single source of truth for the host's per-tile mic view. Pure — no side effects.
    ///
    /// - Parameters:
    ///   - reallyMuted: The participant's ACTUAL mic-muted state from LiveKit track
    ///     events (the real-state channel). `false` == mic live.
    ///   - hostBlocked: The host applied a per-tile mute block to this participant
    ///     (host-intent channel).
    ///   - globalMute: A global Mute-All is active.
    ///   - pendingSelfAction: The host lifted the block / invited the participant while
    ///     the mic is still off, awaiting their tap. Distinguishes "freely self-muted"
    ///     from "permitted, hasn't acted yet" (Finding A). Cleared once `reallyMuted`
    ///     becomes false or a re-block / Mute-All supersedes it.
    ///   - askPending: An "Ask to Unmute" is currently pending / in cooldown (only
    ///     refines the caption between `offCanUnmute` and `askedToUnmute`).
    ///   - isInterviewMode: Interview rooms retain force-restore: activation actions
    ///     force the device on and must show the participant an indicator. This flips
    ///     `activationForcesDevice` only — it does NOT change the cause or which action
    ///     is offered (the host sees the same labels; only execution differs).
    /// - Returns: the derived, internally-consistent `InterMicTileState`.
    @objc public static func deriveMic(reallyMuted: Bool,
                                       hostBlocked: Bool,
                                       globalMute: Bool,
                                       pendingSelfAction: Bool,
                                       askPending: Bool,
                                       isInterviewMode: Bool) -> InterMicTileState {
        let cause: InterMicCause
        let primary: InterMicPrimaryAction
        let secondary: InterMicSecondaryAction

        // Precedence: host block → global mute-all → live → pending → self-muted.
        // `mute` is reachable ONLY from the live branch, so it can never be offered
        // beside a muted caption — this is the structural fix for the old mismatch.
        if hostBlocked {
            cause = .mutedByHost
            primary = .removeMuteAndAsk      // one click: lift my block + invite
            secondary = .none
        } else if globalMute {
            cause = .mutedByMuteAll
            primary = .allowToSpeak          // grant a speak slot
            secondary = .blockMic            // may also enforce an individual block
        } else if !reallyMuted {
            cause = .micOn
            primary = .mute                  // the ONLY state where Mute is offered
            secondary = .none
        } else if pendingSelfAction {
            cause = askPending ? .askedToUnmute : .offCanUnmute
            primary = .askToUnmute
            secondary = .blockMic
        } else {
            cause = .selfMuted
            primary = .askToUnmute
            secondary = .blockMic
        }

        let forces = isInterviewMode && primary.isActivation
        return InterMicTileState(cause: cause,
                                 primaryAction: primary,
                                 secondaryAction: secondary,
                                 activationForcesDevice: forces)
    }
}
