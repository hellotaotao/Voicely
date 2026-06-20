//
//  DetailRecordingControlBar.swift
//  Voicely
//
//  Pause / resume / stop controls shown inside the note detail while a
//  recording is in progress. Used on iPhone, where pushing into the detail
//  hides the library's recording bar. It does NOT own the recording session:
//  the buttons post the same notifications the lock-screen / quick actions use,
//  and the single RecordingControls instance performs the actual work.
//

import SwiftUI

struct DetailRecordingControlBar: View {
    @ObservedObject var audioService: AudioRecordingService
    let onTogglePause: () -> Void
    let onStop: () -> Void

    private var recordingTint: Color {
        audioService.isPaused ? .orange : .red
    }

    private var statusText: String {
        audioService.isPaused ? "Paused" : "Recording"
    }

    var body: some View {
        HStack(spacing: 10) {
            statusCard
            pauseButton
            stopButton
        }
        .padding(8)
        .background(barBackground)
        .overlay(barBorder)
        .shadow(color: Color.black.opacity(0.28), radius: 22, x: 0, y: 12)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: audioService.isPaused)
        .accessibilityIdentifier(AccessibilityIdentifiers.Detail.recordingControls)
    }

    private var statusCard: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(recordingTint)
                .frame(width: 8, height: 8)
                .opacity(audioService.isPaused ? 0.65 : 1.0)

            VStack(alignment: .leading, spacing: 3) {
                Text(statusText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(recordingTint)
                AudioWaveformView(
                    isAnimating: audioService.isRecording && !audioService.isPaused,
                    audioService: audioService
                )
                .frame(height: 18)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(formatDuration(audioService.recordingDuration))
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(recordingTint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(recordingTint.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(recordingTint.opacity(0.22), lineWidth: 1)
        )
    }

    private var pauseButton: some View {
        Button(action: onTogglePause) {
            Image(systemName: audioService.isPaused ? "play.fill" : "pause.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 40, height: 40)
                .background(Color.primary.opacity(0.06), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(audioService.isPaused ? "Resume" : "Pause")
        .accessibilityIdentifier(AccessibilityIdentifiers.Detail.pauseRecordingButton)
    }

    private var stopButton: some View {
        Button(action: onStop) {
            Image(systemName: "stop.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.red))
                .shadow(color: Color.red.opacity(0.35), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop")
        .accessibilityIdentifier(AccessibilityIdentifiers.Detail.stopRecordingButton)
    }

    private var barBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(VoicelyTheme.surface.opacity(0.58))
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.22),
                            Color.white.opacity(0.06),
                            Color.clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
    }

    private var barBorder: some View {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.34),
                        Color.primary.opacity(0.10)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
