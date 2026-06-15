//
//  InterTeamsPanelBridge.swift
//  inter
//
//  AppKit↔SwiftUI bridge for the Teams screen. Replaces the old AppKit
//  InterTeamsPanel + its invite/accept delegate contract with a self-contained
//  SwiftUI screen (Option A): the bridge builds the data layer (REST providers
//  + per-team chat factory + members factory) from the account InterTokenService
//  and hosts `TeamsView` in an NSHostingView. AppDelegate just creates the
//  bridge and drops it into the Teams window — no data is pushed in, no delegate
//  callbacks come out.
//
//  File actions (attach / download) are handled here natively via NSOpenPanel +
//  a presigned-URL download, since SwiftUI can't own AppKit file panels cleanly.
//

import AppKit
import SwiftUI

@objc(InterTeamsPanelBridge)
public final class InterTeamsPanelBridge: NSView {

    private let listViewModel: TeamsListViewModel
    private var hostingView: NSHostingView<TeamsView>?
    /// Manual light/dark for this window (default dark, matching the app). The
    /// design tokens are appearance-aware, so flipping this re-resolves the whole
    /// screen — same mechanism the auth screen uses.
    private var appearanceMode: InterAppearance.Mode = InterAppearance.defaultMode

    @objc public init(frame frameRect: NSRect, tokenService: InterTokenService) {
        let serverURL = tokenService.serverURL ?? ""
        let listProvider = InterTeamsListRESTProvider(serverURL: serverURL, tokenService: tokenService)
        self.listViewModel = TeamsListViewModel(provider: listProvider)

        super.init(frame: frameRect)

        // Capture only values (serverURL + service objects), never `self`, so the
        // factories have no retain cycle with this view.
        let filesProvider = InterTeamFilesRESTProvider(serverURL: serverURL, tokenService: tokenService)

        let makeChat: (InterTeamSummary) -> TeamChatViewModel = { team in
            let socketURL = URL(string: serverURL) ?? URL(string: "http://localhost:0")!
            let realtime = SocketIORealtimeClient(serverURL: socketURL)
            let transport = InterTeamsRESTTransport(serverURL: serverURL, tokenService: tokenService)
            let service = InterTeamsChatService(
                teamId: team.id, transport: transport, realtime: realtime,
                tokenProvider: { [weak tokenService] in tokenService?.currentAccessToken }
            )
            return TeamChatViewModel(
                teamName: team.name,
                currentUserId: tokenService.currentUserId,
                currentDisplayName: tokenService.currentDisplayName ?? "You",
                service: service
            )
        }

        let makeMembers: (InterTeamSummary) -> TeamMembersViewModel = { team in
            let provider = InterTeamMembersRESTProvider(serverURL: serverURL, tokenService: tokenService)
            return TeamMembersViewModel(
                teamId: team.id, teamName: team.name,
                currentUserId: tokenService.currentUserId, provider: provider
            )
        }

        let onDownload: (InterTeamSummary, InterTeamFile) -> Void = { team, file in
            InterTeamsFileActions.download(teamId: team.id, file: file, provider: filesProvider)
        }
        let onAttach: (InterTeamSummary) -> Void = { team in
            InterTeamsFileActions.pickAndUpload(teamId: team.id, provider: filesProvider)
        }

        let root = TeamsView(
            listViewModel: listViewModel,
            makeChatViewModel: makeChat,
            makeMembersViewModel: makeMembers,
            onDownloadFile: onDownload,
            onAttach: onAttach,
            onToggleAppearance: { [weak self] in self?.toggleAppearance() }
        )

        let hosting = NSHostingView(rootView: root)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        self.hostingView = hosting
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Re-apply once we're in a window so the titlebar matches the chrome too.
        applyAppearance()
    }

    /// Flip light/dark and re-resolve the screen + window chrome.
    private func toggleAppearance() {
        appearanceMode = (appearanceMode == .dark) ? .light : .dark
        applyAppearance()
    }

    private func applyAppearance() {
        let ns = InterAppearance.nsAppearance(appearanceMode)
        self.appearance = ns
        hostingView?.appearance = ns
        window?.appearance = ns
    }

    /// Refresh the teams list (call when the window is (re)shown so unread
    /// badges and membership are current).
    @objc public func reload() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            MainActor.assumeIsolated { self.listViewModel.loadTeams() }
        }
    }
}

// MARK: - Native file panels (attach / download)

enum InterTeamsFileActions {

    /// Present an open panel, then upload the chosen file. Errors surface as a
    /// modal alert; on success the file appears in the room via realtime fan-out.
    static func pickAndUpload(teamId: String, provider: InterTeamFilesRESTProvider) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Send"
        panel.message = "Choose a file to share with the team"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            provider.uploadFile(teamId: teamId, fileURL: url) { result in
                DispatchQueue.main.async {
                    if case .failure(let error) = result {
                        presentAlert(title: "Couldn't send file",
                                     message: error.localizedDescription)
                    }
                }
            }
        }
    }

    /// Fetch a presigned URL, download the bytes to ~/Downloads, and reveal the
    /// file in Finder. Errors surface as a modal alert.
    static func download(teamId: String, file: InterTeamFile, provider: InterTeamFilesRESTProvider) {
        provider.presignedURL(teamId: teamId, fileId: file.fileId) { result in
            switch result {
            case .failure(let error):
                DispatchQueue.main.async {
                    presentAlert(title: "Couldn't download file", message: error.localizedDescription)
                }
            case .success(let url):
                URLSession.shared.downloadTask(with: url) { tempURL, _, error in
                    DispatchQueue.main.async {
                        guard let tempURL = tempURL, error == nil else {
                            presentAlert(title: "Couldn't download file",
                                         message: error?.localizedDescription ?? "The download failed.")
                            return
                        }
                        saveToDownloads(tempURL: tempURL, preferredName: file.originalName)
                    }
                }.resume()
            }
        }
    }

    private static func saveToDownloads(tempURL: URL, preferredName: String) {
        let fm = FileManager.default
        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let safeName = preferredName.isEmpty ? "download" : preferredName
        var dest = downloads.appendingPathComponent(safeName)

        // Avoid clobbering an existing file: "name.ext" → "name (1).ext".
        if fm.fileExists(atPath: dest.path) {
            let ext = dest.pathExtension
            let base = dest.deletingPathExtension().lastPathComponent
            var n = 1
            repeat {
                let candidate = "\(base) (\(n))" + (ext.isEmpty ? "" : ".\(ext)")
                dest = downloads.appendingPathComponent(candidate)
                n += 1
            } while fm.fileExists(atPath: dest.path)
        }

        do {
            try fm.moveItem(at: tempURL, to: dest)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch {
            presentAlert(title: "Couldn't save file", message: error.localizedDescription)
        }
    }

    private static func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
