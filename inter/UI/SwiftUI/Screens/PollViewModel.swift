//
//  PollViewModel.swift
//  inter
//
//  Drives the SwiftUI poll panel (in-call floating window). Mirrors the legacy
//  InterPollPanel mode machine — Create (host) / Waiting (participant) /
//  Voting / Results — driven by the InterPollInfo snapshots that AppDelegate
//  pushes via the bridge. Actions flow OUT through callbacks the bridge wires
//  to the legacy InterPollPanelDelegate, so AppDelegate's wiring is unchanged.
//
//  Domain notes (kept faithful to the controller, not the mock):
//    • A participant's vote counts stay stale until the host shares results or
//      ends the poll — only the host aggregates live.
//    • Submitting a vote flips straight to results: the controller immediately
//      echoes didUpdateResults(hasVoted: true) for non-hosts.
//    • "New Poll" is local-only (reset to the create form), exactly like the
//      legacy newPollAction:.
//

import Foundation
import Combine

/// Which screen the poll panel shows. Derived from (poll, isHost, hasVoted).
public enum PollScreen: Equatable {
    /// Host with no poll: the create form.
    case createForm
    /// Participant with no poll: empty "waiting" state.
    case waiting
    /// Participant with an active poll they haven't voted on.
    case voting
    /// Live results (host), post-vote results (participant), or final results.
    case results
}

@MainActor
public final class PollViewModel: ObservableObject {

    public static let minOptions = 2
    public static let maxOptions = 10

    /// Cooldown before "Results shared ✓" reverts so the host can share again.
    static let shareConfirmationSeconds: TimeInterval = 2.5

    // MARK: - State from the controller (via the bridge)

    @Published public private(set) var poll: InterPollInfo?
    @Published public var isHost: Bool = false

    // MARK: - Create-form state (host)

    @Published public var question: String = ""
    @Published public var optionDrafts: [String] = Array(repeating: "", count: PollViewModel.minOptions)
    @Published public var isAnonymous: Bool = false
    @Published public var allowMultiSelect: Bool = false

    // MARK: - Voting state (participant)

    @Published public private(set) var selectedIndices: Set<Int> = []
    @Published public private(set) var voteSubmitted: Bool = false

    // MARK: - Share-results feedback (host)

    @Published public private(set) var resultsShared: Bool = false

    /// Action callbacks — wired by the bridge to the legacy delegate.
    public var onLaunch: ((String, [String], Bool, Bool) -> Void)?
    public var onEndPoll: (() -> Void)?
    public var onShareResults: (() -> Void)?
    public var onSubmitVote: (([Int]) -> Void)?

    public init() {}

    // MARK: - Inputs from the controller

    public func showActivePoll(_ info: InterPollInfo) {
        poll = info
        voteSubmitted = info.hasLocalUserVoted
        selectedIndices = Set(info.localVoteIndices)
        resultsShared = false
    }

    public func updateResults(_ info: InterPollInfo) {
        poll = info
        if info.hasLocalUserVoted {
            voteSubmitted = true
            selectedIndices = Set(info.localVoteIndices)
        }
    }

    public func showEndedPoll(_ info: InterPollInfo) {
        poll = info
        if info.hasLocalUserVoted {
            selectedIndices = Set(info.localVoteIndices)
        }
        resultsShared = false
    }

    public func resetToCreateForm() {
        poll = nil
        voteSubmitted = false
        selectedIndices = []
        resultsShared = false
        question = ""
        optionDrafts = Array(repeating: "", count: Self.minOptions)
        isAnonymous = false
        allowMultiSelect = false
    }

    // MARK: - Derived state

    /// Whether the local user has voted on the current poll (locally submitted
    /// or confirmed by the controller).
    public var hasVoted: Bool {
        voteSubmitted || poll?.hasLocalUserVoted == true
    }

    public var screen: PollScreen {
        guard let poll else { return isHost ? .createForm : .waiting }
        if poll.isActive && !isHost && !hasVoted { return .voting }
        return .results
    }

    public var canAddOption: Bool { optionDrafts.count < Self.maxOptions }
    public var canRemoveOptions: Bool { optionDrafts.count > Self.minOptions }

    public var canLaunch: Bool {
        Self.isLaunchable(question: question, options: optionDrafts)
    }

    public var canSubmitVote: Bool {
        !selectedIndices.isEmpty && !hasVoted && poll?.isActive == true
    }

    // MARK: - Create-form actions (host)

    public func addOption() {
        guard canAddOption else { return }
        optionDrafts.append("")
    }

    public func removeOption(at index: Int) {
        guard canRemoveOptions, optionDrafts.indices.contains(index) else { return }
        optionDrafts.remove(at: index)
    }

    public func launch() {
        guard canLaunch else { return }
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        onLaunch?(trimmed, Self.nonBlankOptions(optionDrafts), isAnonymous, allowMultiSelect)
    }

    // MARK: - Voting actions (participant)

    public func toggleSelection(_ index: Int) {
        guard let poll, poll.isActive, !hasVoted else { return }
        if poll.allowMultiSelect {
            if selectedIndices.contains(index) {
                selectedIndices.remove(index)
            } else {
                selectedIndices.insert(index)
            }
        } else {
            selectedIndices = [index] // radio semantics
        }
    }

    public func submitVote() {
        guard canSubmitVote else { return }
        voteSubmitted = true
        onSubmitVote?(selectedIndices.sorted())
    }

    // MARK: - Host actions

    public func endPoll() {
        guard isHost, poll?.isActive == true else { return }
        onEndPoll?()
    }

    public func shareResults() {
        guard isHost, poll?.isActive == true, !resultsShared else { return }
        resultsShared = true
        onShareResults?()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.shareConfirmationSeconds * 1_000_000_000))
            self?.resultsShared = false
        }
    }

    /// Host's "New Poll" after a poll ends — local reset, no delegate call
    /// (matches the legacy newPollAction:).
    public func newPoll() {
        guard isHost else { return }
        resetToCreateForm()
    }

    // MARK: - Pure helpers (unit-tested)

    /// Options that survive trimming — what actually launches.
    public nonisolated static func nonBlankOptions(_ drafts: [String]) -> [String] {
        drafts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Launch rule (mirrors the legacy panel + controller validation):
    /// non-blank question and 2–10 non-blank options.
    public nonisolated static func isLaunchable(question: String, options: [String]) -> Bool {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let opts = nonBlankOptions(options)
        return !q.isEmpty && opts.count >= minOptions && opts.count <= maxOptions
    }

    /// "36%" — rounded share of total votes for an option.
    public nonisolated static func percentageText(votes: Int, total: Int) -> String {
        guard total > 0, votes > 0 else { return "0%" }
        return "\(Int((Double(votes) / Double(total) * 100).rounded()))%"
    }

    /// "1 vote" / "5 votes" caption under a result bar.
    public nonisolated static func votesCaption(_ count: Int) -> String {
        count == 1 ? "1 vote" : "\(count) votes"
    }
}
