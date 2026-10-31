//
//  PresenceTimelineView.swift
//  inter
//
//  PRESENCE MONITORING (provisional, server flag default OFF).
//
//  The interviewer's evaluation panel, presented as an NSPopover from the
//  control bar. Plain rows on a fixed-dark stage surface: what the camera saw,
//  when, for how long, under which thresholds.
//
//  WHAT THIS VIEW DELIBERATELY DOES NOT RENDER (§7.2): no total, no weighted
//  aggregate, no percentage, no rating, no colour-coded risk level, no ranking
//  and no comparison to any other candidate or session. The reviewer reads
//  "Face not visible, 00:14:02, 17 s" and asks why — which is the entire point.
//
//  Delete this file with PresenceTimelineViewModel.swift to remove the surface.
//  See .agents/tasks/presence-monitoring/REMOVAL.md.
//

import SwiftUI

struct PresenceTimelineView: View {
    @ObservedObject var viewModel: PresenceTimelineViewModel

    @State private var openNoteRowID: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))
            ScrollView {
                VStack(alignment: .leading, spacing: InterSpacing.x3) {
                    summaryBlock
                    eventList
                    footer
                }
                .padding(InterSpacing.x3)
            }
            Divider().overlay(Color.white.opacity(0.08))
            actionRow
        }
        .background(Color(nsColor: InterColor.stageSurface))
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: InterSpacing.x1) {
            HStack(spacing: InterSpacing.x2) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(nsColor: InterColor.primary))
                Text("Presence timeline")
                    .font(InterFont.swiftUI(InterFont.Size.secondary, .semibold))
                    .foregroundColor(Color(nsColor: InterColor.stageText))
                Spacer(minLength: 0)
                Button(action: { viewModel.refresh() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(nsColor: InterColor.stageTextMuted))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .handCursor()
                .help("Refresh")
            }
            Text(viewModel.consentCaption)
                .font(InterFont.swiftUI(InterFont.Size.dense10))
                .foregroundColor(Color(nsColor: InterColor.stageTextMuted))
            if !viewModel.statusText.isEmpty {
                Text(viewModel.statusText)
                    .font(InterFont.swiftUI(InterFont.Size.dense10))
                    .foregroundColor(Color(nsColor: InterStatus.warning))
            }
        }
        .padding(.horizontal, InterSpacing.x3)
        .padding(.vertical, InterSpacing.x2)
    }

    // MARK: - Summary (per type only)

    @ViewBuilder private var summaryBlock: some View {
        if !viewModel.summary.isEmpty {
            VStack(alignment: .leading, spacing: InterSpacing.x1) {
                sectionHeading("What the camera saw")
                ForEach(viewModel.summary) { row in
                    Text(PresenceTimelineViewModel.summaryCaption(row))
                        .font(InterFont.swiftUI(InterFont.Size.caption))
                        .foregroundColor(Color(nsColor: InterColor.stageTextSecondary))
                }
            }
        }
    }

    // MARK: - Events

    @ViewBuilder private var eventList: some View {
        VStack(alignment: .leading, spacing: InterSpacing.x2) {
            sectionHeading("Moments")
            if viewModel.rows.isEmpty {
                Text(viewModel.loaded
                     ? "Nothing recorded for this session."
                     : "Loading…")
                    .font(InterFont.swiftUI(InterFont.Size.caption))
                    .foregroundColor(Color(nsColor: InterColor.stageTextMuted))
            } else {
                ForEach(viewModel.rows) { row in
                    eventRow(row)
                }
            }
        }
    }

    private func eventRow(_ row: PresenceTimelineRow) -> some View {
        VStack(alignment: .leading, spacing: InterSpacing.x1) {
            HStack(spacing: InterSpacing.x2) {
                Text(PresenceTimelineViewModel.offsetCaption(row.offsetMs))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(nsColor: InterColor.stageTextMuted))
                Text(PresenceTimelineViewModel.eventTypeLabel(row.eventType))
                    .font(InterFont.swiftUI(InterFont.Size.caption, .semibold))
                    .foregroundColor(Color(nsColor: InterColor.stageTextSecondary))
                Text(PresenceTimelineViewModel.durationCaption(row.durationMs))
                    .font(InterFont.swiftUI(InterFont.Size.dense10))
                    .foregroundColor(Color(nsColor: InterColor.stageTextMuted))
                Spacer(minLength: 0)
                jumpButton(row)
            }

            ForEach(row.notes) { note in
                HStack(alignment: .top, spacing: InterSpacing.x1) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 9))
                        .foregroundColor(Color(nsColor: InterColor.stageTextMuted))
                        .padding(.top, 2)
                    Text("\(note.author): \(note.text)")
                        .font(InterFont.swiftUI(InterFont.Size.dense10))
                        .foregroundColor(Color(nsColor: InterColor.stageTextMuted))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if row.acceptsNote {
                noteEditor(row)
            }
        }
        .padding(InterSpacing.x2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: InterRadius.md, style: .continuous)
            .fill(Color.white.opacity(0.04)))
    }

    /// Visible but DISABLED when no recording exists, with the honest caption —
    /// the panel must not imply a clip is there to jump to.
    private func jumpButton(_ row: PresenceTimelineRow) -> some View {
        Button(action: { viewModel.jumpTo(row: row) }) {
            HStack(spacing: InterSpacing.x1) {
                Image(systemName: "play.rectangle")
                    .font(.system(size: 9, weight: .semibold))
                Text("Jump")
                    .font(InterFont.swiftUI(InterFont.Size.dense10, .semibold))
            }
            .foregroundColor(Color(nsColor: viewModel.recordingAvailable
                                   ? InterColor.stageTextSecondary
                                   : InterColor.stageTextMuted))
            .padding(.horizontal, InterSpacing.x1_5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: InterRadius.sm)
                .fill(Color.white.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
        .disabled(!viewModel.recordingAvailable)
        .opacity(viewModel.recordingAvailable ? 1 : 0.5)
        .help(viewModel.jumpCaption ?? "Open the recording at this moment")
    }

    @ViewBuilder private func noteEditor(_ row: PresenceTimelineRow) -> some View {
        if openNoteRowID == row.id {
            VStack(alignment: .leading, spacing: InterSpacing.x1) {
                TextField("What did you conclude? (at least 10 characters)",
                          text: Binding(
                            get: { viewModel.noteDrafts[row.id] ?? "" },
                            set: { viewModel.noteDrafts[row.id] = $0 }))
                    .textFieldStyle(.plain)
                    .font(InterFont.swiftUI(InterFont.Size.dense11))
                    .foregroundColor(Color(nsColor: InterColor.stageTextSecondary))
                    .padding(.horizontal, InterSpacing.x2)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: InterRadius.sm)
                        .fill(Color.white.opacity(0.06)))

                let draft = viewModel.noteDrafts[row.id] ?? ""
                HStack(spacing: InterSpacing.x2) {
                    InterButton("Save note", variant: .primary, size: .small,
                                enabled: PresenceTimelineViewModel.noteIsSaveable(draft),
                                action: {
                        viewModel.addNote(row: row, text: draft)
                        openNoteRowID = nil
                    })
                    InterButton("Cancel", variant: .secondary, size: .small,
                                action: { openNoteRowID = nil })
                    Spacer(minLength: 0)
                }
            }
        } else {
            Button(action: { openNoteRowID = row.id }) {
                Text(row.notes.isEmpty ? "Add a note" : "Add another note")
                    .font(InterFont.swiftUI(InterFont.Size.dense10, .semibold))
                    .foregroundColor(Color(nsColor: InterColor.primary))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .handCursor()
        }
    }

    // MARK: - Footer

    @ViewBuilder private var footer: some View {
        if !viewModel.footerCaption.isEmpty {
            VStack(alignment: .leading, spacing: InterSpacing.x1) {
                sectionHeading("Operating point")
                // An event means nothing without the thresholds it was measured
                // under, and a threshold change produces new rows going forward
                // rather than different rows looking back (NISTIR 8280 / §7.5).
                Text(viewModel.footerCaption)
                    .font(InterFont.swiftUI(InterFont.Size.dense10))
                    .foregroundColor(Color(nsColor: InterColor.stageTextMuted))
                    .fixedSize(horizontal: false, vertical: true)
                Text("These are moments to look at, not conclusions. You decide what they mean.")
                    .font(InterFont.swiftUI(InterFont.Size.dense10))
                    .foregroundColor(Color(nsColor: InterColor.stageTextMuted))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: InterSpacing.x2) {
            InterButton("Copy JSON", variant: .secondary, size: .small,
                        action: { viewModel.copyJSON() })
            InterButton("Save CSV", variant: .secondary, size: .small,
                        action: { viewModel.saveCSV() })
            Spacer(minLength: 0)
        }
        .padding(InterSpacing.x3)
    }

    private func sectionHeading(_ text: String) -> some View {
        Text(text.uppercased())
            .font(InterFont.swiftUI(InterFont.Size.dense10, .semibold))
            .tracking(0.8)
            .foregroundColor(Color(nsColor: InterColor.stageTextMuted))
    }
}
