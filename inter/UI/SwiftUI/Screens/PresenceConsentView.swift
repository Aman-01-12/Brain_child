//
//  PresenceConsentView.swift
//  inter
//
//  PRESENCE MONITORING (provisional, server flag default OFF).
//
//  The candidate's pre-join consent screen and — in `.details` mode — the same
//  copy reopened mid-session from the chrome chip. One view, one source of copy
//  (PresenceDisclosure), so the promise made before joining and the explanation
//  given during the session can never drift.
//
//  §7.6 modal archetype on a FIXED-dark stage surface (in-call surfaces are
//  never appearance-aware): centred card, InterColor.stageElevated fill,
//  InterRadius.xxl, 1 pt InterDesignTokens.stageBorder, InterSpacing.x6 padding,
//  on an InterColor.stage scrim.
//
//  THE ACTION ROW IS THE POINT (research memo §7.4 item 7 and the Thuringian
//  ruling in §3.7): the two join buttons are the SAME width and the SAME
//  InterControl.primaryHeight, neither is greyed, neither is styled destructive,
//  and the decline button is not a link. Consent that has no real alternative is
//  not consent, and a visibly weaker decline button is how that gets smuggled in.
//

import SwiftUI

struct PresenceConsentView: View {
    @ObservedObject var viewModel: PresenceConsentViewModel

    private let cardMaxWidth: CGFloat = 600

    var body: some View {
        ZStack {
            Color(nsColor: InterColor.stage)
            card
                .frame(maxWidth: cardMaxWidth)
                .padding(InterSpacing.x6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: InterSpacing.x4) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: InterSpacing.x4) {
                    switch viewModel.state {
                    case .monitoredOffer:        offerBody
                    case .monitoringOffNotice:   noticeBody
                    case .details:               detailsBody
                    }
                }
                .padding(.trailing, InterSpacing.x1)
            }
            actionRow
        }
        .padding(InterSpacing.x6)
        .background(RoundedRectangle(cornerRadius: InterRadius.xxl, style: .continuous)
            .fill(Color(nsColor: InterColor.stageElevated))
            .overlay(RoundedRectangle(cornerRadius: InterRadius.xxl, style: .continuous)
                .strokeBorder(Color(nsColor: InterDesignTokens.stageBorder), lineWidth: 1)))
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: InterSpacing.x2) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Color(nsColor: InterColor.primary))
            Text(viewModel.state == .details
                 ? PresenceDisclosure.detailsHeading
                 : viewModel.title)
                .font(InterFont.swiftUI(InterFont.Size.title, .semibold))
                .foregroundColor(Color(nsColor: InterColor.stageText))
            Spacer(minLength: 0)
        }
    }

    // MARK: - Panes

    private var offerBody: some View {
        VStack(alignment: .leading, spacing: InterSpacing.x4) {
            bodyText(viewModel.subtitle)
            secureModeBlock
            listBlock(heading: PresenceDisclosure.measuredHeading,
                      items: PresenceDisclosure.measuredItems,
                      icon: "circle.fill")
            negativeListBlock
            factRows
            detailsDisclosureRow
            bodyText(PresenceDisclosure.declineExplainer)
        }
    }

    private var noticeBody: some View {
        VStack(alignment: .leading, spacing: InterSpacing.x4) {
            bodyText(PresenceDisclosure.monitoringOffNotice)
            secureModeBlock
            detailsDisclosureRow
        }
    }

    private var detailsBody: some View {
        VStack(alignment: .leading, spacing: InterSpacing.x4) {
            if let label = viewModel.currentIndicatorLabel {
                HStack(spacing: InterSpacing.x2) {
                    Image(systemName: viewModel.monitoringState == 1 ? "eye" : "eye.slash")
                        .font(.system(size: 12, weight: .semibold))
                    Text(label)
                        .font(InterFont.swiftUI(InterFont.Size.caption, .semibold))
                }
                .foregroundColor(Color(nsColor: viewModel.monitoringState == 1
                                       ? InterStatus.success : InterColor.stageTextMuted))
            }
            listBlock(heading: PresenceDisclosure.measuredHeading,
                      items: PresenceDisclosure.measuredItems,
                      icon: "circle.fill")
            negativeListBlock
            factRows
        }
    }

    // MARK: - Blocks

    private var secureModeBlock: some View {
        listBlock(heading: PresenceDisclosure.secureModeHeading,
                  items: viewModel.secureModeItems,
                  icon: "circle.fill")
    }

    /// The negative list, visually distinct because it is the most reassuring and
    /// most differentiating thing on the screen (§7.4 item 2).
    private var negativeListBlock: some View {
        VStack(alignment: .leading, spacing: InterSpacing.x2) {
            Text(PresenceDisclosure.notMeasuredHeading.uppercased())
                .font(InterFont.swiftUI(InterFont.Size.dense11, .semibold))
                .tracking(0.8)
                .foregroundColor(Color(nsColor: InterStatus.success))
            ForEach(PresenceDisclosure.notMeasuredItems, id: \.self) { item in
                HStack(alignment: .top, spacing: InterSpacing.x2) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Color(nsColor: InterStatus.success))
                        .padding(.top, 3)
                    Text(item)
                        .font(InterFont.swiftUI(InterFont.Size.secondary))
                        .lineSpacing(InterFont.lineSpacing(cssLineHeight: 1.6, size: 14))
                        .foregroundColor(Color(nsColor: InterColor.stageTextSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(InterSpacing.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: InterRadius.lg, style: .continuous)
            .fill(Color(nsColor: InterStatus.success).opacity(0.08))
            .overlay(RoundedRectangle(cornerRadius: InterRadius.lg, style: .continuous)
                .strokeBorder(Color(nsColor: InterStatus.success).opacity(0.25), lineWidth: 1)))
    }

    private var factRows: some View {
        VStack(alignment: .leading, spacing: InterSpacing.x2) {
            factRow(icon: "desktopcomputer", text: PresenceDisclosure.whereProcessed)
            factRow(icon: "clock", text: viewModel.storedCopy)
            factRow(icon: "person.2", text: PresenceDisclosure.whoSees)
            factRow(icon: "hand.raised", text: PresenceDisclosure.noAutomatedDecision)
            factRow(icon: "envelope", text: viewModel.rightsCopy)
        }
    }

    private func factRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: InterSpacing.x2) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color(nsColor: InterColor.stageTextMuted))
                .frame(width: 14)
                .padding(.top, 2)
            Text(text)
                .font(InterFont.swiftUI(InterFont.Size.secondary))
                .lineSpacing(InterFont.lineSpacing(cssLineHeight: 1.6, size: 14))
                .foregroundColor(Color(nsColor: InterColor.stageTextSecondary))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func listBlock(heading: String, items: [String], icon: String) -> some View {
        VStack(alignment: .leading, spacing: InterSpacing.x2) {
            Text(heading.uppercased())
                .font(InterFont.swiftUI(InterFont.Size.dense11, .semibold))
                .tracking(0.8)
                .foregroundColor(Color(nsColor: InterColor.stageTextMuted))
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: InterSpacing.x2) {
                    Image(systemName: icon)
                        .font(.system(size: 5, weight: .bold))
                        .foregroundColor(Color(nsColor: InterColor.stageTextMuted))
                        .padding(.top, 7)
                    Text(item)
                        .font(InterFont.swiftUI(InterFont.Size.secondary))
                        .lineSpacing(InterFont.lineSpacing(cssLineHeight: 1.6, size: 14))
                        .foregroundColor(Color(nsColor: InterColor.stageTextSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func bodyText(_ text: String) -> some View {
        Text(text)
            .font(InterFont.swiftUI(InterFont.Size.secondary))
            .lineSpacing(InterFont.lineSpacing(cssLineHeight: 1.6, size: 14))
            .foregroundColor(Color(nsColor: InterColor.stageTextSecondary))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Opens the full list at any time, before joining and mid-session.
    @ViewBuilder private var detailsDisclosureRow: some View {
        if viewModel.state != .details {
            Button(action: { viewModel.showDetails() }) {
                HStack(spacing: InterSpacing.x2) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12, weight: .medium))
                    Text(PresenceConsentViewModel.detailsRowTitle)
                        .font(InterFont.swiftUI(InterFont.Size.caption, .semibold))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundColor(Color(nsColor: InterColor.stageTextSecondary))
                .padding(.horizontal, InterSpacing.x3)
                .frame(height: InterControl.compactHeight)
                .background(RoundedRectangle(cornerRadius: InterRadius.md, style: .continuous)
                    .fill(Color.white.opacity(0.06)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .handCursor()
        }
    }

    // MARK: - Action row

    @ViewBuilder private var actionRow: some View {
        switch viewModel.state {
        case .details:
            HStack(spacing: InterSpacing.x2) {
                Spacer(minLength: 0)
                InterButton(viewModel.detailsOnly
                            ? PresenceConsentViewModel.closeDetailsTitle
                            : PresenceConsentViewModel.backFromDetailsTitle,
                            variant: .secondary,
                            action: { viewModel.dismissDetails() })
                    .keyboardShortcut(.cancelAction)
            }

        case .monitoringOffNotice:
            VStack(spacing: InterSpacing.x2) {
                InterButton(PresenceConsentViewModel.joinOnlyTitle,
                            variant: .primary,
                            fullWidth: true,
                            action: { viewModel.declineMonitoring() })
                    .keyboardShortcut(.defaultAction)
                cancelButton
            }

        case .monitoredOffer:
            VStack(spacing: InterSpacing.x2) {
                // EQUAL WEIGHT, BY CONSTRUCTION: both buttons get the same
                // .primary variant, the same regular size (InterControl
                // .primaryHeight = 40) and an equal share of the row.
                HStack(spacing: InterSpacing.x2) {
                    InterButton(PresenceConsentViewModel.joinMonitoredTitle,
                                variant: .primary,
                                fullWidth: true,
                                action: { viewModel.acceptMonitoring() })
                        .frame(maxWidth: .infinity)
                        .keyboardShortcut(.defaultAction)
                    InterButton(PresenceConsentViewModel.joinUnmonitoredTitle,
                                variant: .primary,
                                fullWidth: true,
                                action: { viewModel.declineMonitoring() })
                        .frame(maxWidth: .infinity)
                }
                cancelButton
            }
        }
    }

    /// Tertiary — the only low-emphasis action on the screen, and it is the one
    /// that does NOT join.
    private var cancelButton: some View {
        Button(action: { viewModel.cancelJoin() }) {
            Text(PresenceConsentViewModel.cancelTitle)
                .font(InterFont.swiftUI(InterFont.Size.dense11))
                .foregroundColor(Color(nsColor: InterColor.stageTextMuted))
                .frame(maxWidth: .infinity)
                .frame(height: InterControl.compactHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
        .keyboardShortcut(.cancelAction)
    }
}
