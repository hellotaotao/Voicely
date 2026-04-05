//
//  BenchmarkView.swift
//  Voicely
//

import SwiftUI
import WhisperKit
import CoreML
import SwiftData

// MARK: - Data model

struct BenchmarkRound: Identifiable {
    let id = UUID()
    let label: String
    let computeUnits: MLComputeUnits

    enum Status { case pending, running, completed, failed }
    var status: Status = .pending
    var elapsed: TimeInterval?
    var rtf: Double?
    var transcriptPreview: String?
    var errorMessage: String?
}

// MARK: - View

@MainActor
struct BenchmarkView: View {
    @EnvironmentObject private var modelManager: ModelManager
    @Query(sort: \VoiceNote.timestamp, order: .reverse) private var voiceNotes: [VoiceNote]

    @State private var selectedNote: VoiceNote?
    @State private var rounds: [BenchmarkRound] = BenchmarkView.makeRounds()
    @State private var isRunning = false
    @State private var benchmarkTask: Task<Void, Never>?

    private static func makeRounds() -> [BenchmarkRound] {
        [
            BenchmarkRound(label: "CPU", computeUnits: .cpuOnly),
            BenchmarkRound(label: "CPU + GPU", computeUnits: .cpuAndGPU),
            BenchmarkRound(label: "CPU + ANE", computeUnits: .cpuAndNeuralEngine),
        ]
    }

    private var canStart: Bool {
        selectedNote != nil && modelManager.isModelLoaded() && !isRunning
    }

    private var fastestRoundIndex: Int? {
        let completed = rounds.enumerated().compactMap { idx, r -> (Int, TimeInterval)? in
            guard r.status == .completed, let t = r.elapsed else { return nil }
            return (idx, t)
        }
        return completed.min(by: { $0.1 < $1.1 })?.0
    }

    var body: some View {
        List {
            audioPickerSection
            if !modelManager.isModelLoaded() {
                Section {
                    Label("Load a model in Settings before running a benchmark.", systemImage: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                        .font(.callout)
                }
            }
            resultsSection
            controlsSection
        }
        .navigationTitle("Compute Benchmark")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            benchmarkTask?.cancel()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    // MARK: - Sections

    private var audioPickerSection: some View {
        let notesWithAudio = voiceNotes.filter { !$0.audioFilePath.isEmpty }
        return Section("Select Recording") {
            if notesWithAudio.isEmpty {
                Text("No recordings found. Record something first.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(notesWithAudio) { note in
                    Button {
                        selectedNote = note
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(note.title)
                                    .foregroundColor(.primary)
                                Text(String(format: "%.1fs", note.duration))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if selectedNote?.id == note.id {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var resultsSection: some View {
        Section("Results") {
            if rounds.allSatisfy({ $0.status == .pending }) {
                Text("Results will appear here after running.")
                    .foregroundColor(.secondary)
                    .font(.callout)
            } else {
                ForEach(rounds.indices, id: \.self) { i in
                    roundRow(for: rounds[i], isFastest: fastestRoundIndex == i)
                }
            }
        }
    }

    private var controlsSection: some View {
        Section {
            if isRunning {
                Button(role: .destructive) {
                    benchmarkTask?.cancel()
                } label: {
                    Label("Cancel", systemImage: "stop.circle")
                        .frame(maxWidth: .infinity)
                }
                Text("First run compiles CoreML models and may take several minutes per round.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Button {
                    startBenchmark()
                } label: {
                    Label("Start Benchmark", systemImage: "timer")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!canStart)
                .buttonStyle(.borderedProminent)

                if let fastestIdx = fastestRoundIndex {
                    Button {
                        applyFastest(index: fastestIdx)
                    } label: {
                        Label("Apply Fastest (\(rounds[fastestIdx].label))", systemImage: "checkmark.seal")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: - Round row

    @ViewBuilder
    private func roundRow(for round: BenchmarkRound, isFastest: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(round.label).font(.headline)
                Spacer()
                roundStatusBadge(for: round, isFastest: isFastest)
            }
            if let elapsed = round.elapsed, let rtf = round.rtf {
                HStack(spacing: 16) {
                    Label(String(format: "%.2fs", elapsed), systemImage: "clock")
                    Label(String(format: "RTF %.2f×", rtf), systemImage: "speedometer")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            if let preview = round.transcriptPreview, !preview.isEmpty {
                Text("\"\(preview)\"")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            if let error = round.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(isFastest ? Color.green.opacity(0.08) : Color.clear)
    }

    @ViewBuilder
    private func roundStatusBadge(for round: BenchmarkRound, isFastest: Bool) -> some View {
        switch round.status {
        case .pending:
            Text("—").foregroundColor(.secondary)
        case .running:
            ProgressView().scaleEffect(0.7)
        case .completed:
            if isFastest {
                Label("Fastest", systemImage: "star.fill")
                    .font(.caption)
                    .foregroundColor(.green)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            }
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundColor(.red)
        }
    }

    // MARK: - Benchmark logic

    private func startBenchmark() {
        guard let note = selectedNote,
              let modelFolder = modelManager.whisperKit?.modelFolder else { return }

        rounds = BenchmarkView.makeRounds()

        benchmarkTask = Task {
            UIApplication.shared.isIdleTimerDisabled = true
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            isRunning = true
            defer { isRunning = false }

            guard let audioURL = await CloudStorageManager.shared.prepareFileForReading(at: note.audioFilePath) else {
                return
            }
            let audioPath = audioURL.path
            let audioDuration = note.duration

            for i in rounds.indices {
                if Task.isCancelled { break }
                rounds[i].status = .running

                do {
                    let computeOptions = ModelComputeOptions(
                        audioEncoderCompute: rounds[i].computeUnits,
                        textDecoderCompute: rounds[i].computeUnits
                    )
                    let config = WhisperKitConfig(
                        computeOptions: computeOptions,
                        verbose: false,
                        prewarm: false,
                        load: false,
                        download: false
                    )
                    let tempKit = try await WhisperKit(config)
                    tempKit.modelFolder = modelFolder
                    try await tempKit.prewarmModels()
                    try await tempKit.loadModels()

                    let start = Date()
                    let results = try await tempKit.transcribe(
                        audioPath: audioPath,
                        decodeOptions: DecodingOptions(
                            task: .transcribe,
                            skipSpecialTokens: true,
                            withoutTimestamps: true
                        )
                    ) { _ in Task.isCancelled ? false : nil }
                    let elapsed = Date().timeIntervalSince(start)

                    let fullText = results.map(\.text).joined(separator: " ")
                    let rtf = audioDuration > 0 ? elapsed / audioDuration : 0

                    rounds[i].elapsed = elapsed
                    rounds[i].rtf = rtf
                    rounds[i].transcriptPreview = String(fullText.prefix(100))
                    rounds[i].status = .completed
                } catch {
                    if Task.isCancelled {
                        rounds[i].status = .pending
                    } else {
                        rounds[i].errorMessage = error.localizedDescription
                        rounds[i].status = .failed
                    }
                }
            }
        }
    }

    private func applyFastest(index: Int) {
        let units = rounds[index].computeUnits
        modelManager.encoderComputeUnits = units
        modelManager.decoderComputeUnits = units
    }
}

#Preview {
    NavigationView {
        BenchmarkView()
    }
}
