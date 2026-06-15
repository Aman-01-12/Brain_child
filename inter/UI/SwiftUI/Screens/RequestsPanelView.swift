//
//  RequestsPanelView.swift
//  inter
//
//  Host/co-host Requests panel — one surface for all pending requests,
//  segregated by type (Raised Hands · Screen Share · Mic Unlock · Camera
//  Unlock). Lives on the stage (fixed-dark tokens). Participants never see
//  this panel — they get button-state feedback instead.
//

import SwiftUI

struct RequestsPanelView: View {
    @ObservedObject var viewModel: RequestsPanelViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Requests")
                    .font(InterFont.swiftUI(14, .semibold))
                    .foregroundColor(.interStageText)
                Spacer()
                if viewModel.totalCount > 0 {
                    Text("\(viewModel.totalCount)")
                        .font(InterFont.swiftUI(10, .bold))
                        .foregroundColor(.interStageText)
                        .padding(.horizontal, InterSpacing.x1_5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Capsule().fill(Color(nsColor: InterColor.primary)))
                }
            }
            .padding(.horizontal, InterSpacing.x4)
            .frame(height: 44)

            Divider().overlay(Color.white.opacity(0.08))

            if viewModel.requests.isEmpty {
                VStack(spacing: InterSpacing.x2) {
                    Image(systemName: "tray")
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.3))
                    Text("No pending requests.")
                        .font(InterFont.swiftUI(12))
                        .foregroundColor(.interStageTextMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: InterSpacing.x2) {
                        ForEach(viewModel.activeKinds) { kind in
                            section(kind)
                        }
                    }
                    .padding(InterSpacing.x3)
                }
            }
        }
        .background(Color(nsColor: InterColor.stageSurface))
    }

    private func section(_ kind: CallRequestKind) -> some View {
        VStack(alignment: .leading, spacing: InterSpacing.x1) {
            HStack(spacing: InterSpacing.x1_5) {
                Image(systemName: kind.icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(kind.rawValue.uppercased())
                    .font(InterFont.swiftUI(9, .bold))
                    .tracking(1.0)
            }
            .foregroundColor(.interStageTextMuted)
            .padding(.top, InterSpacing.x1)

            ForEach(viewModel.rows(for: kind)) { request in
                requestRow(request)
            }
        }
    }

    private func requestRow(_ request: CallRequest) -> some View {
        HStack(spacing: InterSpacing.x2_5) {
            Circle()
                .fill(Color(nsColor: InterColor.primary).opacity(0.25))
                .frame(width: 26, height: 26)
                .overlay(Text(HomeViewModel.initials(from: request.displayName))
                    .font(InterFont.swiftUI(9, .bold))
                    .foregroundColor(.interStageText))
            Text(request.displayName)
                .font(InterFont.swiftUI(12, .medium))
                .foregroundColor(.interStageTextSecondary)
                .lineLimit(1)
            Spacer(minLength: InterSpacing.x1)
            Button(action: { viewModel.approve(request) }) {
                Text(RequestsPanelViewModel.approveLabel(for: request.kind))
                    .font(InterFont.swiftUI(10, .semibold))
                    .foregroundColor(.interStageText)
                    .padding(.horizontal, InterSpacing.x2)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: InterRadius.md, style: .continuous)
                        .fill(Color(nsColor: InterColor.primary)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .handCursor()
            if request.kind.supportsDeny {
                Button(action: { viewModel.deny(request) }) {
                    Text("Deny")
                        .font(InterFont.swiftUI(10, .semibold))
                        .foregroundColor(Color(nsColor: InterStatus.danger))
                        .padding(.horizontal, InterSpacing.x2)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: InterRadius.md, style: .continuous)
                            .strokeBorder(Color(nsColor: InterStatus.danger).opacity(0.5), lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .handCursor()
            }
        }
        .padding(.horizontal, InterSpacing.x2_5)
        .padding(.vertical, InterSpacing.x1_5)
        .background(RoundedRectangle(cornerRadius: InterRadius.md, style: .continuous)
            .fill(Color.white.opacity(0.05)))
    }
}
