//
//  QAViewModelTests.swift
//  interTests
//
//  Tests the Q&A panel view model: tab filtering/counts, ask-composer rules,
//  action routing through the callbacks, and the anonymous caption logic.
//

import XCTest
@testable import inter

private func qInfo(_ id: String, _ text: String, votes: Int = 0, answered: Bool = false,
                   highlighted: Bool = false, anonymous: Bool = false,
                   asker: String = "Alice", upvoted: Bool = false) -> InterQuestionInfo {
    let q = InterQuestion(id: id, askerIdentity: "u-\(id)", askerName: asker, text: text,
                          timestamp: 1_000_000, upvoteCount: votes, isAnswered: answered,
                          isHighlighted: highlighted, isAnonymous: anonymous)
    return InterQuestionInfo(from: q, hasUpvoted: upvoted)
}

@MainActor
final class QAViewModelTests: XCTestCase {

    // MARK: - Filtering + counts

    func testTabFilteringPreservesOrder() {
        let qs = [qInfo("1", "a"), qInfo("2", "b", answered: true), qInfo("3", "c")]
        XCTAssertEqual(QAViewModel.filter(qs, tab: .open).map { $0.questionId }, ["1", "3"])
        XCTAssertEqual(QAViewModel.filter(qs, tab: .answered).map { $0.questionId }, ["2"])
    }

    func testCountsPerTab() {
        let vm = QAViewModel()
        vm.setQuestions([qInfo("1", "a"), qInfo("2", "b", answered: true), qInfo("3", "c")])
        XCTAssertEqual(vm.count(for: .open), 2)
        XCTAssertEqual(vm.count(for: .answered), 1)
        XCTAssertEqual(vm.visibleQuestions.count, 2, "default tab is Open")
        vm.tab = .answered
        XCTAssertEqual(vm.visibleQuestions.map { $0.questionId }, ["2"])
    }

    // MARK: - Ask composer

    func testCanAskRequiresNonBlankDraft() {
        let vm = QAViewModel()
        XCTAssertFalse(vm.canAsk)
        vm.draft = "   "
        XCTAssertFalse(vm.canAsk)
        vm.draft = "Why?"
        XCTAssertTrue(vm.canAsk)
    }

    func testSubmitTrimsSendsAndResets() {
        let vm = QAViewModel()
        var sent: (text: String, anon: Bool)?
        vm.onSubmit = { sent = ($0, $1) }
        vm.draft = "  Why is the sky blue?  "
        vm.isAnonymous = true

        vm.submit()

        XCTAssertEqual(sent?.text, "Why is the sky blue?")
        XCTAssertEqual(sent?.anon, true)
        XCTAssertTrue(vm.draft.isEmpty, "draft clears after ask")
        XCTAssertFalse(vm.isAnonymous, "anonymous resets after ask")
    }

    func testSubmitBlankIsNoOp() {
        let vm = QAViewModel()
        var called = false
        vm.onSubmit = { _, _ in called = true }
        vm.draft = "   "
        vm.submit()
        XCTAssertFalse(called)
    }

    // MARK: - Actions

    func testUpvoteRoutesOnlyWhenNotAlreadyVoted() {
        let vm = QAViewModel()
        var upvoted: [String] = []
        vm.onUpvote = { upvoted.append($0) }

        vm.upvote(qInfo("1", "a"))
        vm.upvote(qInfo("2", "b", upvoted: true)) // already voted — no-op

        XCTAssertEqual(upvoted, ["1"])
    }

    func testHostActionsRouteQuestionIds() {
        let vm = QAViewModel()
        var highlighted: [String] = [], answered: [String] = [], dismissed: [String] = []
        vm.onHighlight = { highlighted.append($0) }
        vm.onMarkAnswered = { answered.append($0) }
        vm.onDismiss = { dismissed.append($0) }

        vm.highlight(qInfo("1", "a"))
        vm.markAnswered(qInfo("2", "b"))
        vm.dismiss(qInfo("3", "c"))

        XCTAssertEqual(highlighted, ["1"])
        XCTAssertEqual(answered, ["2"])
        XCTAssertEqual(dismissed, ["3"])
    }

    // MARK: - Anonymous caption

    func testCaptionHidesAskerFromNonHosts() {
        let anon = qInfo("1", "a", anonymous: true, asker: "Carol")
        XCTAssertEqual(QAViewModel.captionText(for: anon, isViewerHost: false), "ANONYMOUS")
        XCTAssertEqual(QAViewModel.captionText(for: anon, isViewerHost: true), "CAROL",
                       "host still sees the real asker")
        let named = qInfo("2", "b", asker: "Bob")
        XCTAssertEqual(QAViewModel.captionText(for: named, isViewerHost: false), "BOB")
    }
}
