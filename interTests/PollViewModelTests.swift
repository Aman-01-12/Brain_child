//
//  PollViewModelTests.swift
//  interTests
//
//  Tests the poll panel view model: screen derivation (create / waiting /
//  voting / results), create-form rules (option bounds, launch validation),
//  vote selection semantics (radio vs multi), action routing through the
//  callbacks, and the pure text helpers.
//

import XCTest
@testable import inter

private func pollInfo(question: String = "Ship it?",
                      options: [(String, Int)] = [("Yes", 0), ("No", 0)],
                      anonymous: Bool = false, multi: Bool = false,
                      status: InterPollStatus = .active,
                      hasVoted: Bool = false, localVotes: [Int] = []) -> InterPollInfo {
    let poll = InterPoll(question: question,
                         options: options.map { InterPollOption(label: $0.0, voteCount: $0.1) },
                         createdBy: "host-1",
                         isAnonymous: anonymous,
                         allowMultiSelect: multi,
                         status: status)
    return InterPollInfo(from: poll, hasVoted: hasVoted, localVotes: localVotes)
}

@MainActor
final class PollViewModelTests: XCTestCase {

    // MARK: - Screen derivation

    func testNoPollShowsCreateFormForHostWaitingForParticipant() {
        let vm = PollViewModel()
        vm.isHost = true
        XCTAssertEqual(vm.screen, .createForm)
        vm.isHost = false
        XCTAssertEqual(vm.screen, .waiting)
    }

    func testActivePollScreens() {
        let vm = PollViewModel()
        vm.isHost = false
        vm.showActivePoll(pollInfo())
        XCTAssertEqual(vm.screen, .voting, "participant who hasn't voted sees the voting UI")

        vm.isHost = true
        XCTAssertEqual(vm.screen, .results, "host always sees live results")

        vm.isHost = false
        vm.updateResults(pollInfo(hasVoted: true, localVotes: [0]))
        XCTAssertEqual(vm.screen, .results, "voted participant sees results")
    }

    func testEndedPollShowsResultsForEveryone() {
        let vm = PollViewModel()
        vm.isHost = false
        vm.showEndedPoll(pollInfo(status: .ended))
        XCTAssertEqual(vm.screen, .results)
    }

    func testResetToCreateFormClearsEverything() {
        let vm = PollViewModel()
        vm.isHost = true
        vm.question = "Q"
        vm.optionDrafts = ["a", "b", "c"]
        vm.isAnonymous = true
        vm.allowMultiSelect = true
        vm.showActivePoll(pollInfo(hasVoted: true, localVotes: [1]))

        vm.resetToCreateForm()

        XCTAssertNil(vm.poll)
        XCTAssertEqual(vm.screen, .createForm)
        XCTAssertEqual(vm.question, "")
        XCTAssertEqual(vm.optionDrafts, ["", ""])
        XCTAssertFalse(vm.isAnonymous)
        XCTAssertFalse(vm.allowMultiSelect)
        XCTAssertTrue(vm.selectedIndices.isEmpty)
        XCTAssertFalse(vm.hasVoted)
    }

    // MARK: - Create form

    func testOptionBounds() {
        let vm = PollViewModel()
        XCTAssertEqual(vm.optionDrafts.count, 2)
        XCTAssertFalse(vm.canRemoveOptions, "minimum of 2 options")
        vm.removeOption(at: 0)
        XCTAssertEqual(vm.optionDrafts.count, 2, "remove below minimum is a no-op")

        for _ in 0..<20 { vm.addOption() }
        XCTAssertEqual(vm.optionDrafts.count, 10, "capped at 10 options")
        XCTAssertFalse(vm.canAddOption)

        vm.optionDrafts[2] = "third"
        vm.removeOption(at: 2)
        XCTAssertEqual(vm.optionDrafts.count, 9)
        XCTAssertFalse(vm.optionDrafts.contains("third"))
    }

    func testCanLaunchRequiresQuestionAndTwoNonBlankOptions() {
        let vm = PollViewModel()
        vm.optionDrafts = ["Yes", "No"]
        XCTAssertFalse(vm.canLaunch, "blank question")
        vm.question = "   "
        XCTAssertFalse(vm.canLaunch)
        vm.question = "Ship it?"
        XCTAssertTrue(vm.canLaunch)
        vm.optionDrafts = ["Yes", "   "]
        XCTAssertFalse(vm.canLaunch, "needs 2 non-blank options")
    }

    func testLaunchTrimsAndRoutes() {
        let vm = PollViewModel()
        var sent: (q: String, opts: [String], anon: Bool, multi: Bool)?
        vm.onLaunch = { sent = ($0, $1, $2, $3) }
        vm.question = "  Ship it?  "
        vm.optionDrafts = [" Yes ", "", "No"]
        vm.isAnonymous = true
        vm.allowMultiSelect = true

        vm.launch()

        XCTAssertEqual(sent?.q, "Ship it?")
        XCTAssertEqual(sent?.opts, ["Yes", "No"], "blank drafts dropped, labels trimmed")
        XCTAssertEqual(sent?.anon, true)
        XCTAssertEqual(sent?.multi, true)
    }

    func testLaunchInvalidIsNoOp() {
        let vm = PollViewModel()
        var called = false
        vm.onLaunch = { _, _, _, _ in called = true }
        vm.question = "Q"
        vm.optionDrafts = ["only one", ""]
        vm.launch()
        XCTAssertFalse(called)
    }

    // MARK: - Voting

    func testSingleSelectUsesRadioSemantics() {
        let vm = PollViewModel()
        vm.showActivePoll(pollInfo(multi: false))
        vm.toggleSelection(0)
        vm.toggleSelection(1)
        XCTAssertEqual(vm.selectedIndices, [1], "single-select replaces the selection")
    }

    func testMultiSelectTogglesIndividually() {
        let vm = PollViewModel()
        vm.showActivePoll(pollInfo(options: [("A", 0), ("B", 0), ("C", 0)], multi: true))
        vm.toggleSelection(0)
        vm.toggleSelection(2)
        XCTAssertEqual(vm.selectedIndices, [0, 2])
        vm.toggleSelection(0)
        XCTAssertEqual(vm.selectedIndices, [2])
    }

    func testSubmitVoteRoutesSortedIndicesOnce() {
        let vm = PollViewModel()
        var votes: [[Int]] = []
        vm.onSubmitVote = { votes.append($0) }
        vm.showActivePoll(pollInfo(options: [("A", 0), ("B", 0), ("C", 0)], multi: true))

        XCTAssertFalse(vm.canSubmitVote, "no selection yet")
        vm.toggleSelection(2)
        vm.toggleSelection(0)
        XCTAssertTrue(vm.canSubmitVote)

        vm.submitVote()
        XCTAssertEqual(votes, [[0, 2]])
        XCTAssertTrue(vm.hasVoted)
        XCTAssertEqual(vm.screen, .results, "voting flips straight to results")

        vm.submitVote()
        XCTAssertEqual(votes.count, 1, "double submit is a no-op")
        vm.toggleSelection(1)
        XCTAssertEqual(vm.selectedIndices, [0, 2], "selection locked after voting")
    }

    func testUpdateResultsSyncsConfirmedLocalVote() {
        let vm = PollViewModel()
        vm.showActivePoll(pollInfo())
        vm.updateResults(pollInfo(options: [("Yes", 3), ("No", 1)], hasVoted: true, localVotes: [0]))
        XCTAssertTrue(vm.hasVoted)
        XCTAssertEqual(vm.selectedIndices, [0])
    }

    // MARK: - Host actions

    func testEndPollHostOnlyAndActiveOnly() {
        let vm = PollViewModel()
        var ended = 0
        vm.onEndPoll = { ended += 1 }

        vm.isHost = false
        vm.showActivePoll(pollInfo())
        vm.endPoll()
        XCTAssertEqual(ended, 0, "participants cannot end")

        vm.isHost = true
        vm.endPoll()
        XCTAssertEqual(ended, 1)

        vm.showEndedPoll(pollInfo(status: .ended))
        vm.endPoll()
        XCTAssertEqual(ended, 1, "no end on an ended poll")
    }

    func testShareResultsRoutesOnceThenCoolsDown() {
        let vm = PollViewModel()
        var shared = 0
        vm.onShareResults = { shared += 1 }
        vm.isHost = true
        vm.showActivePoll(pollInfo())

        vm.shareResults()
        vm.shareResults() // guarded while the confirmation is showing

        XCTAssertEqual(shared, 1)
        XCTAssertTrue(vm.resultsShared)
    }

    func testNewPollIsHostOnlyLocalReset() {
        let vm = PollViewModel()
        vm.showEndedPoll(pollInfo(status: .ended))

        vm.isHost = false
        vm.newPoll()
        XCTAssertNotNil(vm.poll, "participants cannot reset")

        vm.isHost = true
        vm.newPoll()
        XCTAssertNil(vm.poll)
        XCTAssertEqual(vm.screen, .createForm)
    }

    // MARK: - Pure helpers

    func testNonBlankOptionsTrimsAndDrops() {
        XCTAssertEqual(PollViewModel.nonBlankOptions([" a ", "", "  ", "b"]), ["a", "b"])
    }

    func testPercentageText() {
        XCTAssertEqual(PollViewModel.percentageText(votes: 36, total: 64), "56%")
        XCTAssertEqual(PollViewModel.percentageText(votes: 0, total: 64), "0%")
        XCTAssertEqual(PollViewModel.percentageText(votes: 0, total: 0), "0%")
        XCTAssertEqual(PollViewModel.percentageText(votes: 64, total: 64), "100%")
    }

    func testVotesCaptionPluralizes() {
        XCTAssertEqual(PollViewModel.votesCaption(0), "0 votes")
        XCTAssertEqual(PollViewModel.votesCaption(1), "1 vote")
        XCTAssertEqual(PollViewModel.votesCaption(5), "5 votes")
    }
}
