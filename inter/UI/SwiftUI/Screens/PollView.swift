//
//  PollView.swift
//  inter
//
//  SwiftUI poll panel for the in-call floating window. Visual language follows
//  the design handoff (ref_poll_{dark,light}.png / PollMock.tsx): host create
//  form (question + option fields with remove, add-option link, anonymous /
//  multi-select checkboxes, Launch), live results with animated % bars and a
//  pulsing "Live · N responses" pill, participant voting (radio / checkbox
//  rows, emerald Submit), and final results (emerald bar + ✓ for the local
//  user's choice, violet otherwise; host "New Poll" link).
//
//  Faithful-to-domain differences from the mock: a participant waiting state
//  exists (the mock only previews the four populated modes), and a
//  participant's counts stay as last shared by the host (only the host
//  aggregates live).
//
//  The host window pins its appearance (in-call surfaces), so the dynamic
//  tokens resolve correctly without any screen-local appearance logic.
//

import SwiftUI

struct PollView: View {
    @ObservedObject var viewModel: PollViewModel

    var body: some View {
        ScrollView {
            Group {
                switch viewModel.screen {
                case .createForm: createForm
                case .waiting:    waitingState
                case .voting:     votingSection
                case .results:    resultsSection
                }
            }
            .padding(InterSpacing.x5)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: InterColor.card))
        .interResignsFocusOnBackgroundTap()
    }

    // MARK: - Host · create form

    private var createForm: some View {
        VStack(alignment: .leading, spacing: InterSpacing.x4) {
            VStack(alignment: .leading, spacing: InterSpacing.x1_5) {
                fieldLabel("Question")
                InterInputField(placeholder: "Type your question here…",
                                text: $viewModel.question)
            }

            VStack(alignment: .leading, spacing: InterSpacing.x2) {
                fieldLabel("Options")
                ForEach(viewModel.optionDrafts.indices, id: \.self) { index in
                    HStack(spacing: InterSpacing.x2) {
                        InterInputField(placeholder: "Option \(index + 1)",
                                        text: $viewModel.optionDrafts[index])
                        if viewModel.canRemoveOptions {
                            removeOptionButton(index)
                        }
                    }
                }
                addOptionButton
            }

            Divider().overlay(Color(nsColor: InterColor.border))

            VStack(alignment: .leading, spacing: InterSpacing.x2) {
                checkboxRow("Anonymous voting", isOn: $viewModel.isAnonymous)
                checkboxRow("Allow multiple selections", isOn: $viewModel.allowMultiSelect)
            }

            InterButton("Launch Poll", variant: .primary, size: .medium, fullWidth: true,
                        enabled: viewModel.canLaunch, action: { viewModel.launch() })
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(InterFont.swiftUI(InterFont.Size.caption, .semibold))
            .foregroundColor(Color(nsColor: InterColor.mutedForeground))
    }

    private func removeOptionButton(_ index: Int) -> some View {
        Button(action: { viewModel.removeOption(at: index) }) {
            Image(systemName: "trash")
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
        .help("Remove option")
    }

    private var addOptionButton: some View {
        Button(action: { viewModel.addOption() }) {
            HStack(spacing: InterSpacing.x1_5) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                Text(viewModel.canAddOption ? "Add Option" : "Add Option (max 10)")
                    .font(InterFont.swiftUI(InterFont.Size.caption, .semibold))
            }
            .foregroundColor(Color(nsColor: viewModel.canAddOption
                ? InterColor.primary
                : InterColor.mutedForeground))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
        .disabled(!viewModel.canAddOption)
    }

    private func checkboxRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(InterFont.swiftUI(InterFont.Size.secondary))
                .foregroundColor(Color(nsColor: InterColor.foreground))
        }
        .toggleStyle(.checkbox)
        .handCursor()
    }

    // MARK: - Participant · waiting (no active poll)

    private var waitingState: some View {
        VStack(spacing: InterSpacing.x2) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(Color(nsColor: InterColor.mutedForeground))
            Text("No active poll")
                .font(InterFont.swiftUI(13, .semibold))
                .foregroundColor(Color(nsColor: InterColor.foreground))
            Text("When the host launches a poll, it appears here.")
                .font(InterFont.swiftUI(InterFont.Size.caption))
                .foregroundColor(Color(nsColor: InterColor.mutedForeground))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, InterSpacing.x8)
    }

    // MARK: - Participant · voting

    private var votingSection: some View {
        VStack(alignment: .leading, spacing: InterSpacing.x4) {
            if let poll = viewModel.poll {
                questionText(poll.question)

                if poll.isAnonymous {
                    Text("Your vote is anonymous.")
                        .font(InterFont.swiftUI(InterFont.Size.dense11))
                        .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                }

                VStack(spacing: InterSpacing.x2) {
                    ForEach(0..<poll.optionLabels.count, id: \.self) { index in
                        voteOptionRow(label: poll.optionLabels[index],
                                      index: index,
                                      multiSelect: poll.allowMultiSelect)
                    }
                }

                InterButton(viewModel.voteSubmitted ? "Vote submitted ✓" : "Submit Vote",
                            variant: .success, size: .medium, fullWidth: true,
                            enabled: viewModel.canSubmitVote,
                            action: { viewModel.submitVote() })
            }
        }
    }

    private func voteOptionRow(label: String, index: Int, multiSelect: Bool) -> some View {
        let selected = viewModel.selectedIndices.contains(index)
        let shape = RoundedRectangle(cornerRadius: InterRadius.xl, style: .continuous)
        return Button(action: { viewModel.toggleSelection(index) }) {
            HStack(spacing: InterSpacing.x3) {
                selectionIndicator(selected: selected, multiSelect: multiSelect)
                Text(label)
                    .font(InterFont.swiftUI(InterFont.Size.secondary, .medium))
                    .foregroundColor(Color(nsColor: selected ? InterColor.primary : InterColor.foreground))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, InterSpacing.x4)
            .padding(.vertical, InterSpacing.x3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                shape.fill(selected ? Color(nsColor: InterColor.primary).opacity(0.10) : .clear)
                    .overlay(shape.strokeBorder(selected
                        ? Color(nsColor: InterColor.primary)
                        : Color(nsColor: InterColor.border), lineWidth: 1))
            )
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .handCursor()
    }

    /// Radio circle (single-select) or rounded square (multi-select).
    private func selectionIndicator(selected: Bool, multiSelect: Bool) -> some View {
        let outer: CGFloat = 16
        return ZStack {
            indicatorShape(multiSelect: multiSelect)
                .strokeBorder(selected
                    ? Color(nsColor: InterColor.primary)
                    : Color(nsColor: InterColor.mutedForeground), lineWidth: 2)
                .background(indicatorShape(multiSelect: multiSelect)
                    .fill(selected ? Color(nsColor: InterColor.primary) : .clear))
            if selected {
                if multiSelect {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(.white)
                        .frame(width: 8, height: 8)
                } else {
                    Circle().fill(.white).frame(width: 6, height: 6)
                }
            }
        }
        .frame(width: outer, height: outer)
    }

    private func indicatorShape(multiSelect: Bool) -> some InsettableShape {
        // Circle for radio, 3pt-rounded square for checkbox — as AnyInsettableShape
        // doesn't exist, model both with a RoundedRectangle (circle = full radius).
        RoundedRectangle(cornerRadius: multiSelect ? 3 : 8, style: .continuous)
    }

    // MARK: - Results (host live · participant voted · ended)

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: InterSpacing.x3) {
            if let poll = viewModel.poll {
                statusRow(poll)
                questionText(poll.question)

                VStack(alignment: .leading, spacing: InterSpacing.x3) {
                    ForEach(0..<poll.optionLabels.count, id: \.self) { index in
                        resultRow(poll: poll, index: index)
                    }
                }

                if viewModel.isHost && poll.isActive {
                    hostActiveFooter
                } else if viewModel.isHost && poll.isEnded {
                    newPollFooter
                }
            }
        }
    }

    @ViewBuilder
    private func statusRow(_ poll: InterPollInfo) -> some View {
        if poll.isActive && viewModel.isHost {
            HStack {
                Spacer(minLength: 0)
                livePill(responses: poll.totalVotes)
            }
        } else if poll.isEnded {
            Text("Poll ended · \(PollViewModel.votesCaption(poll.totalVotes)) total")
                .font(InterFont.swiftUI(InterFont.Size.dense11, .semibold))
                .foregroundColor(Color(nsColor: InterColor.mutedForeground))
        } else if viewModel.hasVoted {
            Text("Vote submitted ✓")
                .font(InterFont.swiftUI(InterFont.Size.dense11, .semibold))
                .foregroundColor(Color(nsColor: InterStatus.success))
        }
    }

    private func questionText(_ question: String) -> some View {
        Text(question) // pure Text — user content never executes
            .font(InterFont.swiftUI(InterFont.Size.secondary, .semibold))
            .foregroundColor(Color(nsColor: InterColor.foreground))
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func resultRow(poll: InterPollInfo, index: Int) -> some View {
        let count = index < poll.optionVoteCounts.count ? poll.optionVoteCounts[index] : 0
        let pct = poll.votePercentage(at: index)
        let localVoted = viewModel.selectedIndices.contains(index) && viewModel.hasVoted

        return VStack(alignment: .leading, spacing: InterSpacing.x1) {
            HStack(alignment: .firstTextBaseline, spacing: InterSpacing.x2) {
                Text(localVoted ? "\(poll.optionLabels[index]) ✓" : poll.optionLabels[index])
                    .font(InterFont.swiftUI(InterFont.Size.secondary, localVoted ? .semibold : .regular))
                    .foregroundColor(Color(nsColor: InterColor.foreground))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: InterSpacing.x2)
                Text(PollViewModel.percentageText(votes: count, total: poll.totalVotes))
                    .font(InterFont.swiftUI(InterFont.Size.secondary, .semibold).monospacedDigit())
                    .foregroundColor(Color(nsColor: InterColor.foreground))
            }

            resultBar(pct: pct, count: count, emerald: localVoted)

            Text(PollViewModel.votesCaption(count))
                .font(InterFont.swiftUI(InterFont.Size.dense10))
                .foregroundColor(Color(nsColor: InterColor.mutedForeground))
        }
    }

    /// Animated 0–100% bar. Emerald for the local user's choice, violet otherwise.
    private func resultBar(pct: Double, count: Int, emerald: Bool) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(nsColor: InterColor.secondary))
                Capsule()
                    .fill(Color(nsColor: emerald ? InterStatus.success : InterColor.primary))
                    .frame(width: barWidth(pct: pct, count: count, available: geo.size.width))
            }
            .animation(.easeInOut(duration: 0.25), value: pct)
        }
        .frame(height: 10) // h-2.5
    }

    /// ≥2pt sliver for any option with votes so it never disappears (legacy parity).
    private func barWidth(pct: Double, count: Int, available: CGFloat) -> CGFloat {
        let width = available * CGFloat(pct)
        return count > 0 ? max(width, 2) : width
    }

    private func livePill(responses: Int) -> some View {
        HStack(spacing: InterSpacing.x1_5) {
            PulsingDot()
            Text("Live · \(responses) responses")
                .font(InterFont.swiftUI(InterFont.Size.dense11, .semibold))
        }
        .foregroundColor(Color(nsColor: InterStatus.success))
        .padding(.horizontal, InterSpacing.x2_5)
        .padding(.vertical, InterSpacing.x1)
        .background(
            Capsule().fill(Color(nsColor: InterStatus.success).opacity(0.10))
                .overlay(Capsule().strokeBorder(Color(nsColor: InterStatus.success).opacity(0.30),
                                                lineWidth: 1))
        )
    }

    // MARK: - Footers

    private var hostActiveFooter: some View {
        VStack(spacing: InterSpacing.x3) {
            Divider().overlay(Color(nsColor: InterColor.border))
            HStack(spacing: InterSpacing.x3) {
                InterButton("End Poll", systemImage: "stop.fill",
                            variant: .dangerOutline, size: .medium, fullWidth: true,
                            action: { viewModel.endPoll() })
                InterButton(viewModel.resultsShared ? "Results shared ✓" : "Share Results",
                            systemImage: "square.and.arrow.up",
                            variant: viewModel.resultsShared ? .success : .primary,
                            size: .medium, fullWidth: true,
                            enabled: !viewModel.resultsShared,
                            action: { viewModel.shareResults() })
            }
        }
        .padding(.top, InterSpacing.x1)
    }

    private var newPollFooter: some View {
        VStack(alignment: .leading, spacing: InterSpacing.x3) {
            Divider().overlay(Color(nsColor: InterColor.border))
            Button(action: { viewModel.newPoll() }) {
                HStack(spacing: InterSpacing.x1_5) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                    Text("New Poll")
                        .font(InterFont.swiftUI(InterFont.Size.caption, .semibold))
                }
                .foregroundColor(Color(nsColor: InterColor.primary))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .handCursor()
        }
        .padding(.top, InterSpacing.x1)
    }
}

/// Small emerald dot that pulses while a poll is live.
private struct PulsingDot: View {
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(Color(nsColor: InterStatus.success))
            .frame(width: 6, height: 6)
            .opacity(pulsing ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}
