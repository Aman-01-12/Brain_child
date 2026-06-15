//
//  QAViewModel.swift
//  inter
//
//  Drives the SwiftUI Q&A panel (the in-call question board). Holds the
//  question list pushed by InterQAController (already sorted: highlighted →
//  upvotes → time), the Open/Answered tab selection, and the ask-composer
//  state. Actions flow OUT through callbacks the bridge wires to the legacy
//  InterQAPanelDelegate, so AppDelegate's wiring is unchanged.
//
//  Domain notes (kept faithful to the controller, not the mock):
//    • Dismiss REMOVES a question for everyone — nothing is retained, so there
//      is no "Dismissed" tab (it would always be empty).
//    • "Answer live" / "Open for questions" have no backing feature — omitted.
//

import Foundation
import Combine

public enum QATab: String, CaseIterable {
    case open = "Open"
    case answered = "Answered"
}

@MainActor
public final class QAViewModel: ObservableObject {

    @Published public private(set) var questions: [InterQuestionInfo] = []
    @Published public var tab: QATab = .open
    @Published public var draft: String = ""
    @Published public var isAnonymous: Bool = false
    @Published public var isHost: Bool = false

    /// Action callbacks — wired by the bridge to the legacy delegate.
    public var onSubmit: ((String, Bool) -> Void)?
    public var onUpvote: ((String) -> Void)?
    public var onHighlight: ((String) -> Void)?
    public var onMarkAnswered: ((String) -> Void)?
    public var onDismiss: ((String) -> Void)?

    public init() {}

    // MARK: - Inputs from the controller

    public func setQuestions(_ questions: [InterQuestionInfo]) {
        self.questions = questions
    }

    // MARK: - Derived state

    /// Questions for the selected tab, preserving the controller's sort order.
    public var visibleQuestions: [InterQuestionInfo] {
        QAViewModel.filter(questions, tab: tab)
    }

    public func count(for tab: QATab) -> Int {
        QAViewModel.filter(questions, tab: tab).count
    }

    /// Whether the Ask control is enabled (non-empty after trimming).
    public var canAsk: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Actions

    public func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onSubmit?(text, isAnonymous)
        draft = ""
        isAnonymous = false
    }

    public func upvote(_ question: InterQuestionInfo) {
        guard !question.hasLocalUserUpvoted else { return } // controller dedups; avoid no-op spam
        onUpvote?(question.questionId)
    }

    public func highlight(_ question: InterQuestionInfo) {
        onHighlight?(question.questionId)
    }

    public func markAnswered(_ question: InterQuestionInfo) {
        onMarkAnswered?(question.questionId)
    }

    public func dismiss(_ question: InterQuestionInfo) {
        onDismiss?(question.questionId)
    }

    // MARK: - Pure helpers (unit-tested)

    /// Tab filter: Open = not answered, Answered = answered. Order is preserved
    /// (the controller already sorts highlighted → upvotes → time).
    public nonisolated static func filter(_ questions: [InterQuestionInfo], tab: QATab) -> [InterQuestionInfo] {
        switch tab {
        case .open:     return questions.filter { !$0.isAnswered }
        case .answered: return questions.filter { $0.isAnswered }
        }
    }

    /// Caption above the question text: the asker's display name (uppercased,
    /// "ANONYMOUS" for hidden askers — hosts still see the real name).
    public nonisolated static func captionText(for question: InterQuestionInfo, isViewerHost: Bool) -> String {
        question.displayName(isViewerHost: isViewerHost).uppercased()
    }
}
