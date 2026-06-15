//
//  QAView.swift
//  inter
//
//  SwiftUI Q&A board for the in-call floating window. Visual language follows
//  the design handoff (ref_qa_{dark,light}.png / QAMock.tsx): a tab strip with
//  count badges, an ask-composer (input + Anonymous checkbox + Ask), and
//  question cards (caption + text + upvote pill + host actions) with violet /
//  emerald tints for highlighted / answered. Faithful-to-domain differences
//  from the mock: no "Dismissed" tab (dismiss removes for everyone), and no
//  "Answer live" / "Open for questions" controls (no backing feature).
//
//  The host window pins its appearance (in-call surfaces), so the dynamic
//  tokens resolve correctly without any screen-local appearance logic.
//

import SwiftUI

struct QAView: View {
    @ObservedObject var viewModel: QAViewModel
    @FocusState private var askFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            composer
            questionList
        }
        .background(Color(nsColor: InterColor.card))
        .interResignsFocusOnBackgroundTap()
    }

    // MARK: - Tab strip (Open | Answered, violet active underline + count badges)

    private var tabStrip: some View {
        HStack(spacing: 0) {
            ForEach(QATab.allCases, id: \.self) { tab in
                tabButton(tab)
            }
        }
        .background(Color(nsColor: InterColor.muted))
    }

    private func tabButton(_ tab: QATab) -> some View {
        let isActive = viewModel.tab == tab
        return Button(action: { viewModel.tab = tab }) {
            HStack(spacing: InterSpacing.x1_5) {
                Text(tab.rawValue)
                    .font(InterFont.swiftUI(12, .semibold))
                    .foregroundColor(isActive
                        ? Color(nsColor: InterColor.primary)
                        : Color(nsColor: InterColor.mutedForeground))
                Text("\(viewModel.count(for: tab))")
                    .font(InterFont.swiftUI(10, .semibold))
                    .foregroundColor(isActive
                        ? Color(nsColor: InterColor.primary)
                        : Color(nsColor: InterColor.mutedForeground))
                    .padding(.horizontal, InterSpacing.x1)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Capsule().fill(isActive
                        ? Color(nsColor: InterColor.primary).opacity(0.16)
                        : Color(nsColor: InterColor.secondary)))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, InterSpacing.x2)
            .contentShape(Rectangle())
            .overlay(
                Rectangle()
                    .fill(Color(nsColor: InterColor.primary))
                    .frame(height: 2)
                    .opacity(isActive ? 1 : 0),
                alignment: .bottom
            )
        }
        .buttonStyle(.plain)
        .handCursor()
    }

    // MARK: - Ask composer (input + Anonymous + Ask)

    private var composer: some View {
        HStack(spacing: InterSpacing.x2) {
            TextField("Ask a question…", text: $viewModel.draft)
                .textFieldStyle(.plain)
                .font(InterFont.swiftUI(13))
                .padding(.horizontal, InterSpacing.x3)
                .frame(height: 32) // h-8
                .background(
                    RoundedRectangle(cornerRadius: InterRadius.md, style: .continuous)
                        .fill(Color(nsColor: InterColor.inputBackground))
                        .overlay(RoundedRectangle(cornerRadius: InterRadius.md, style: .continuous)
                            .strokeBorder(Color(nsColor: askFocused ? InterColor.ring : InterColor.border),
                                          lineWidth: askFocused ? 1.5 : 1))
                )
                .focused($askFocused)
                .onSubmit { viewModel.submit() }

            Toggle(isOn: $viewModel.isAnonymous) {
                Text("Anonymous")
                    .font(InterFont.swiftUI(12))
                    .foregroundColor(Color(nsColor: InterColor.mutedForeground))
            }
            .toggleStyle(.checkbox)
            .handCursor()
            .help("Hide your name from participants (the host still sees it)")

            InterButton("Ask", variant: .primary, size: .compact,
                        enabled: viewModel.canAsk, action: { viewModel.submit() })
        }
        .padding(.horizontal, InterSpacing.x3)
        .padding(.top, InterSpacing.x3)
        .padding(.bottom, InterSpacing.x2)
    }

    // MARK: - Question list

    private var questionList: some View {
        ScrollView {
            LazyVStack(spacing: InterSpacing.x2) {
                if viewModel.visibleQuestions.isEmpty {
                    Text("No questions in this tab.")
                        .font(InterFont.swiftUI(13))
                        .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, InterSpacing.x8)
                } else {
                    ForEach(viewModel.visibleQuestions, id: \.questionId) { question in
                        QAQuestionCard(
                            question: question,
                            isHost: viewModel.isHost,
                            caption: QAViewModel.captionText(for: question, isViewerHost: viewModel.isHost),
                            onUpvote: { viewModel.upvote(question) },
                            onHighlight: { viewModel.highlight(question) },
                            onMarkAnswered: { viewModel.markAnswered(question) },
                            onDismiss: { viewModel.dismiss(question) }
                        )
                    }
                }
            }
            .padding(InterSpacing.x3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - One question card

private struct QAQuestionCard: View {
    let question: InterQuestionInfo
    let isHost: Bool
    let caption: String
    var onUpvote: () -> Void
    var onHighlight: () -> Void
    var onMarkAnswered: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: InterSpacing.x2) {
            // Caption — asker (or ANONYMOUS) + time, dense uppercase.
            HStack(spacing: InterSpacing.x1_5) {
                Text(caption)
                    .font(InterFont.swiftUI(10, .bold))
                    .tracking(0.5)
                    .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                    .lineLimit(1)
                Text(question.formattedTime)
                    .font(InterFont.swiftUI(10))
                    .foregroundColor(Color(nsColor: InterColor.mutedForeground).opacity(0.7))
            }

            Text(question.text) // pure Text — user content never executes
                .font(InterFont.swiftUI(13))
                .foregroundColor(Color(nsColor: InterColor.cardForeground))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            // Actions — upvote pill + host controls.
            HStack(spacing: InterSpacing.x2) {
                upvotePill
                if isHost && !question.isAnswered {
                    actionChip(question.isHighlighted ? "Highlighted" : "Highlight",
                               systemImage: "pin",
                               active: question.isHighlighted,
                               action: onHighlight)
                    actionChip("Mark Answered", systemImage: "checkmark.circle",
                               active: false, action: onMarkAnswered)
                }
                Spacer(minLength: 0)
                if isHost && !question.isAnswered {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(nsColor: InterStatus.danger))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .handCursor()
                    .help("Dismiss (removes for everyone)")
                }
            }
        }
        .padding(InterSpacing.x3 + 2) // p-3.5
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: InterRadius.xl, style: .continuous)
                .fill(cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: InterRadius.xl, style: .continuous)
                        .strokeBorder(cardBorder, lineWidth: 1)
                )
        )
    }

    // Highlighted = violet tint · Answered = emerald tint · default = card.
    private var cardFill: Color {
        if question.isHighlighted && !question.isAnswered {
            return Color(nsColor: InterColor.primary).opacity(0.10)
        }
        if question.isAnswered {
            return Color(nsColor: InterStatus.success).opacity(0.10)
        }
        return Color(nsColor: InterColor.card)
    }

    private var cardBorder: Color {
        if question.isHighlighted && !question.isAnswered {
            return Color(nsColor: InterColor.primary).opacity(0.35)
        }
        if question.isAnswered {
            return Color(nsColor: InterStatus.success).opacity(0.35)
        }
        return Color(nsColor: InterColor.border)
    }

    // ▲ N — violet when the local user has voted, muted otherwise.
    private var upvotePill: some View {
        Button(action: onUpvote) {
            Text("▲ \(question.upvoteCount)")
                .font(InterFont.swiftUI(11, .semibold))
                .foregroundColor(question.hasLocalUserUpvoted
                    ? .white
                    : Color(nsColor: InterColor.mutedForeground))
                .padding(.horizontal, InterSpacing.x2_5)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: InterRadius.md, style: .continuous)
                    .fill(question.hasLocalUserUpvoted
                        ? Color(nsColor: InterColor.primary)
                        : Color(nsColor: InterColor.muted)))
        }
        .buttonStyle(.plain)
        .handCursor()
        .disabled(question.hasLocalUserUpvoted)
        .help(question.hasLocalUserUpvoted ? "You upvoted this" : "Upvote")
        .accessibilityLabel("\(question.upvoteCount) upvotes")
    }

    private func actionChip(_ title: String, systemImage: String, active: Bool,
                            action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: InterRadius.md, style: .continuous)
        return Button(action: action) {
            HStack(spacing: InterSpacing.x1) {
                Image(systemName: systemImage).font(.system(size: 9, weight: .semibold))
                Text(title).font(InterFont.swiftUI(11, .semibold))
            }
            .foregroundColor(active
                ? Color(nsColor: InterColor.primary)
                : Color(nsColor: InterColor.mutedForeground))
            .padding(.horizontal, InterSpacing.x2_5)
            .padding(.vertical, 3)
            .background(
                shape.fill(active ? Color(nsColor: InterColor.primary).opacity(0.14) : .clear)
                    .overlay(shape.strokeBorder(active
                        ? Color(nsColor: InterColor.primary).opacity(0.4)
                        : Color(nsColor: InterColor.border), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .handCursor()
    }
}
