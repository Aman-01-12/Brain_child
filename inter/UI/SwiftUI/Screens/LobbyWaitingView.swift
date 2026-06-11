//
//  LobbyWaitingView.swift
//  inter
//
//  SwiftUI port of the participant-side waiting room (`lobby`, participant view). Visual
//  source: inter-design-handoff/react-reference/mocks/LobbyMock.tsx (participant view, 5
//  states). Behaviour preserved from `InterLobbyWaitingView` via `InterLobbyWaitingBridgeView`.
//

import SwiftUI

public struct LobbyWaitingView: View {

    @ObservedObject var viewModel: LobbyWaitingViewModel

    public init(viewModel: LobbyWaitingViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: InterSpacing.x5) {
            icon
            VStack(spacing: InterSpacing.x2) {
                Text(viewModel.title)
                    .font(InterFont.swiftUI(InterFont.Size.heading, .semibold))
                    .foregroundStyle(Color(nsColor: InterColor.foreground))
                Text(viewModel.message)
                    .font(InterFont.swiftUI(InterFont.Size.secondary))
                    .foregroundStyle(Color(nsColor: InterColor.mutedForeground))
                    .multilineTextAlignment(.center)
                if viewModel.showsPosition {
                    Text("Your position in queue: \(viewModel.position)")
                        .font(InterFont.swiftUI(InterFont.Size.secondary))
                        .foregroundStyle(Color(nsColor: InterColor.mutedForeground))
                        .monospacedDigit()
                }
            }
            if let title = viewModel.buttonTitle {
                actionButton(title)
            }
        }
        .padding(.vertical, 48)
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: InterColor.card))
    }

    private var icon: some View {
        // Spinner is anchored to the icon's OWN bottom-trailing corner with a small overhang
        // (mock: `absolute -bottom-1 -right-1`). Using an oversized container here would
        // detach the spinner from the glyph, so overlay directly on the sized image.
        Image(systemName: viewModel.iconSystemName)
            .font(.system(size: 34, weight: .regular))
            .foregroundStyle(accentColor)
            .overlay(alignment: .bottomTrailing) {
                if viewModel.showsSpinner {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.85)
                        .offset(x: 7, y: 3)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: viewModel.state)
    }

    private func actionButton(_ title: String) -> some View {
        InterButton(title,
                    variant: viewModel.buttonIsPrimary ? .primary : .secondary,
                    size: .medium,
                    action: { viewModel.cancel() })
    }

    private var accentColor: Color {
        switch viewModel.accent {
        case .brand:   return Color(nsColor: InterColor.primary)
        case .danger:  return Color(nsColor: InterStatus.danger)
        case .success: return Color(nsColor: InterStatus.success)
        }
    }
}
