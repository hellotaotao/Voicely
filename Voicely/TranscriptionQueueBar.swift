//
//  TranscriptionQueueBar.swift
//  Voicely
//

import SwiftUI

extension TranscriptionWaitReason {
    var badgeText: String {
        switch self {
        case .inLine(let position): return position == 1 ? "Next up" : "#\(position) in line"
        case .waitingForModel: return "Waiting for model"
        case .waitingForAudio: return "Waiting for audio"
        case .waitingForOtherDevice: return "On another device"
        case .pausedInBackground: return "Paused in background"
        case .startingSoon: return "Queued"
        }
    }

    var badgeSystemImage: String {
        switch self {
        case .inLine, .startingSoon: return "clock.arrow.circlepath"
        case .waitingForModel: return "cpu"
        case .waitingForAudio: return "icloud.and.arrow.down"
        case .waitingForOtherDevice: return "laptopcomputer.and.iphone"
        case .pausedInBackground: return "pause.circle"
        }
    }

    /// One line for a list row preview.
    var summary: String {
        switch self {
        case .inLine: return "Waiting for its turn to transcribe."
        case .waitingForModel: return "Transcribes once the speech model has loaded."
        case .waitingForAudio: return "The audio hasn't synced to this device yet."
        case .waitingForOtherDevice: return "Recorded on another device, which transcribes it."
        case .pausedInBackground: return "Resumes when the app is back in the foreground."
        case .startingSoon: return "Queued for transcription."
        }
    }

    /// The full explanation for the detail view.
    func explanation(activeTitle: String?) -> Text {
        switch self {
        case .inLine(let position):
            guard let activeTitle else {
                return position == 1
                    ? Text("Starting now.")
                    : Text("\(position - 1) more ahead of it in the transcription queue.")
            }
            return position == 1
                ? Text("Next in line. It starts as soon as “\(activeTitle)” finishes.")
                : Text("“\(activeTitle)” is transcribing, then \(position - 1) more ahead of it.")
        case .waitingForModel:
            return Text("Transcription starts once the speech model has loaded.")
        case .waitingForAudio:
            return Text("The audio hasn't reached this device yet. Transcription continues automatically once it arrives.")
        case .waitingForOtherDevice:
            return Text("Recorded on another device, which transcribes it. To transcribe it on this device instead, tap Transcribe Now.")
        case .pausedInBackground:
            return Text("Paused while the app was in the background. It resumes when you return.")
        case .startingSoon:
            return Text("Waiting to start. It switches to live progress once the local task begins.")
        }
    }
}

/// Pinned above the note list: what is transcribing now and what waits, and why.
struct TranscriptionQueueBar: View {
    struct WaitingNote: Identifiable, Equatable {
        let id: UUID
        let title: String
        let reason: TranscriptionWaitReason
    }

    let activeNoteID: UUID?
    let activeTitle: String?
    let activeProgress: Float
    let waiting: [WaitingNote]
    let onSelect: (UUID) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button {
                if let activeNoteID { onSelect(activeNoteID) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: activeNoteID == nil ? "pause.circle" : "waveform")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(activeNoteID == nil ? Color.secondary : VoicelyTheme.accent)
                        .symbolEffect(.variableColor.iterative, isActive: activeNoteID != nil)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(activeNoteID == nil ? "Not transcribing" : "Transcribing")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(activeTitle ?? firstWaitingSummary)
                            .font(.footnote.weight(.semibold))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    if activeNoteID != nil {
                        Text("\(Int((activeProgress * 100).rounded()))%")
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(activeNoteID == nil)
            .accessibilityIdentifier(AccessibilityIdentifiers.Library.transcriptionQueueActive)

            if !waiting.isEmpty {
                Menu {
                    Section("Waiting") {
                        ForEach(waiting) { note in
                            Button {
                                onSelect(note.id)
                            } label: {
                                Label {
                                    Text(note.title)
                                    Text(note.reason.badgeText)
                                } icon: {
                                    Image(systemName: note.reason.badgeSystemImage)
                                }
                            }
                        }
                    }
                } label: {
                    PillBadge(text: "\(waiting.count) waiting", systemImage: "clock.arrow.circlepath", variant: .warning)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityIdentifier(AccessibilityIdentifiers.Library.transcriptionQueueWaiting)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(VoicelyTheme.surface)
        )
        .overlay(alignment: .bottom) {
            if activeNoteID != nil {
                ProgressView(value: activeProgress)
                    .progressViewStyle(.linear)
                    .tint(VoicelyTheme.accent)
                    .scaleEffect(x: 1, y: 0.5, anchor: .bottom)
                    .padding(.horizontal, 12)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.075), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var firstWaitingSummary: String {
        guard let first = waiting.first else { return "" }
        return waiting.count == 1 ? first.reason.badgeText : "\(first.reason.badgeText) and more"
    }
}
