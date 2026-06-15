//
//  TeamMembersView.swift
//  inter
//
//  "Manage members" sheet for a team: lists active members (avatar + name +
//  email + role chip), lets an owner/admin instant-add by email and remove
//  members, and lets a plain member leave. Visual language follows the design
//  handoff member rows + the app's shared components (InterInputField,
//  InterButton, InterBanner). All text is pure SwiftUI `Text` (paranoid H7).
//

import SwiftUI

struct TeamMembersView: View {
    @StateObject private var viewModel: TeamMembersViewModel
    var onClose: () -> Void

    /// The view owns its view model for the sheet's lifetime (created once via
    /// the factory), so the caller can build it lazily when the sheet appears.
    init(makeViewModel: @escaping () -> TeamMembersViewModel, onClose: @escaping () -> Void) {
        _viewModel = StateObject(wrappedValue: makeViewModel())
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color(nsColor: InterColor.border))
            content
        }
        .frame(width: 440, height: 540)
        .background(Color(nsColor: InterColor.card))
        .interResignsFocusOnBackgroundTap()
        .onAppear { viewModel.load() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: InterSpacing.x2_5) {
            TeamAvatarTile(name: viewModel.teamName, seed: viewModel.teamId, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("Members")
                    .font(InterFont.swiftUI(15, .semibold))
                    .foregroundColor(Color(nsColor: InterColor.cardForeground))
                Text(viewModel.teamName)
                    .font(InterFont.swiftUI(11))
                    .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                    .lineLimit(1)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .handCursor()
            .help("Close")
        }
        .padding(.horizontal, InterSpacing.x4)
        .frame(height: 56)
    }

    // MARK: - Content

    private var content: some View {
        VStack(spacing: InterSpacing.x3) {
            if viewModel.canManage { addRow }

            if let err = viewModel.errorMessage {
                InterBanner(err, variant: .error)
            } else if let info = viewModel.infoMessage {
                InterBanner(info, variant: .success)
            }

            membersList
        }
        .padding(InterSpacing.x4)
    }

    private var addRow: some View {
        let showInvalid = !viewModel.draftEmail.isEmpty
            && !TeamMembersViewModel.isPlausibleEmail(viewModel.draftEmail)
        return HStack(spacing: InterSpacing.x2) {
            InterInputField(
                placeholder: "Add member by email",
                text: $viewModel.draftEmail,
                hasError: showInvalid,
                onSubmit: { viewModel.addMember() }
            )
            InterButton("Add", variant: .primary, size: .medium,
                        isLoading: viewModel.isAdding, enabled: viewModel.canAdd,
                        action: { viewModel.addMember() })
        }
    }

    private var membersList: some View {
        ScrollView {
            LazyVStack(spacing: InterSpacing.x1) {
                ForEach(viewModel.members) { member in
                    TeamMemberRow(
                        member: member,
                        canRemove: viewModel.canRemove(member),
                        isSelf: isSelf(member),
                        onRemove: { viewModel.removeMember(member) }
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func isSelf(_ member: InterTeamMember) -> Bool {
        // A plain member only ever sees a removable row for themselves.
        !viewModel.canManage && viewModel.canRemove(member)
    }
}

// MARK: - One member row

private struct TeamMemberRow: View {
    let member: InterTeamMember
    let canRemove: Bool
    let isSelf: Bool
    var onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: InterSpacing.x2_5) {
            avatar
            VStack(alignment: .leading, spacing: 1) {
                Text(member.displayName)
                    .font(InterFont.swiftUI(13, .semibold))
                    .foregroundColor(Color(nsColor: InterColor.cardForeground))
                    .lineLimit(1)
                Text(member.email)
                    .font(InterFont.swiftUI(11))
                    .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: InterSpacing.x2)
            roleChip
            if canRemove {
                if isSelf {
                    Button(action: onRemove) {
                        Text("Leave")
                            .font(InterFont.swiftUI(11, .semibold))
                            .foregroundColor(Color(nsColor: InterStatus.danger))
                    }
                    .buttonStyle(.plain).handCursor().help("Leave this team")
                } else {
                    Button(action: onRemove) {
                        Image(systemName: "person.badge.minus")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Color(nsColor: InterStatus.danger).opacity(isHovering ? 1 : 0.75))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).handCursor().help("Remove \(member.displayName)")
                }
            }
        }
        .padding(.horizontal, InterSpacing.x2_5)
        .padding(.vertical, InterSpacing.x2)
        .background(
            RoundedRectangle(cornerRadius: InterRadius.lg, style: .continuous)
                .fill(isHovering ? Color(nsColor: InterColor.accent).opacity(0.5) : .clear)
        )
        .onHover { isHovering = $0 }
    }

    private var avatar: some View {
        Circle()
            .fill(Color(nsColor: InterColor.primary).opacity(0.18))
            .frame(width: 32, height: 32)
            .overlay(
                Text(TeamChatViewModel.initials(from: member.displayName))
                    .font(InterFont.swiftUI(11, .bold))
                    .foregroundColor(Color(nsColor: InterColor.primary))
            )
    }

    @ViewBuilder private var roleChip: some View {
        let (fg, label): (NSColor, String) = {
            switch member.role {
            case "owner": return (InterColor.primary, "Owner")
            case "admin": return (InterStatus.brand, "Admin")
            default:      return (InterColor.mutedForeground, "Member")
            }
        }()
        Text(label)
            .font(InterFont.swiftUI(10, .semibold))
            .foregroundColor(Color(nsColor: fg))
            .padding(.horizontal, InterSpacing.x1_5)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color(nsColor: fg).opacity(0.14)))
    }
}
