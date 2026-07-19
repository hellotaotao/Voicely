//
//  BenchmarkView.swift
//  Voicely
//

import SwiftUI
import WhisperKit
import CoreML
import SwiftData

// MARK: - MLComputeUnits display helper

extension MLComputeUnits {
    var shortName: String {
        switch self {
        case .cpuOnly:            return "CPU"
        case .cpuAndGPU:          return "GPU"
        case .cpuAndNeuralEngine: return "ANE"
        default:                  return "Auto"
        }
    }
}

// MARK: - Data model

struct BenchmarkRound: Identifiable {
    let id = UUID()
    let label: String
    let encoderUnits: MLComputeUnits
    let decoderUnits: MLComputeUnits

    enum Status { case pending, running, completed, failed }
    var status: Status = .pending
    var elapsed: TimeInterval?
    var rtf: Double?
    var transcriptPreview: String?
    var errorMessage: String?
}

// MARK: - Audio availability

/// Whether a recording's audio is usable for benchmarking on this device.
enum AudioAvailability {
    case ready      // Downloaded locally, ready to read
    case inCloud    // Exists in iCloud but not yet downloaded to this device
    case missing    // Not synced to this device at all
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
    @State private var startError: String?
    @State private var isPreparingAudio = false

    private static func makeRounds() -> [BenchmarkRound] {
        [
            // Pure configurations
            BenchmarkRound(label: "CPU | CPU",         encoderUnits: .cpuOnly,            decoderUnits: .cpuOnly),
            BenchmarkRound(label: "GPU | GPU",         encoderUnits: .cpuAndGPU,          decoderUnits: .cpuAndGPU),
            BenchmarkRound(label: "ANE | ANE",         encoderUnits: .cpuAndNeuralEngine,  decoderUnits: .cpuAndNeuralEngine),
            // Mixed — encoder and decoder on different hardware to test pipeline overlap
            BenchmarkRound(label: "ANE | GPU",         encoderUnits: .cpuAndNeuralEngine,  decoderUnits: .cpuAndGPU),
            BenchmarkRound(label: "GPU | ANE",         encoderUnits: .cpuAndGPU,          decoderUnits: .cpuAndNeuralEngine),
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

    // Show recordings between 30s and 5 minutes — short enough to benchmark quickly,
    // long enough to be representative. Cap at 8 items, shortest first.
    private static let minDuration: TimeInterval = 30
    private static let maxDuration: TimeInterval = 300

    private func audioAvailability(for note: VoiceNote) -> AudioAvailability {
        let manager = CloudStorageManager.shared
        guard let url = manager.getFileURL(for: note.audioFilePath) else { return .missing }
        if manager.isAudioFileMissing(at: url) { return .missing }
        // A real file on disk means it's downloaded and ready; if only the
        // ".icloud" placeholder exists, it still needs to be pulled from iCloud.
        return FileManager.default.fileExists(atPath: url.path) ? .ready : .inCloud
    }

    // Recordings eligible for benchmarking, paired with their audio availability.
    // Anything not yet synced to this device (.missing) is dropped so users can't
    // pick a recording that has no audio to transcribe.
    private var benchmarkCandidates: [(note: VoiceNote, availability: AudioAvailability)] {
        // `audioAvailability` hits the filesystem twice per note, and this runs
        // from `body` — so cap the list *before* the I/O rather than after, or a
        // large library pays for dozens of stat calls on every re-render. A few
        // extra candidates are checked to refill the cap when some are missing.
        var results: [(note: VoiceNote, availability: AudioAvailability)] = []
        let eligible = voiceNotes
            .filter { !$0.audioFilePath.isEmpty
                && $0.duration >= Self.minDuration
                && $0.duration <= Self.maxDuration }
            .sorted { $0.duration < $1.duration }

        for note in eligible {
            let availability = audioAvailability(for: note)
            guard availability != .missing else { continue }
            results.append((note: note, availability: availability))
            if results.count == 8 { break }
        }
        return results
    }

    private func durationString(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }

    // Quiet pattern (Apple's own): already-local recordings show nothing —
    // being ready is the normal state. Only iCloud items still needing a
    // download are tagged. `.missing` is filtered out upstream.
    @ViewBuilder
    private func availabilityBadge(_ availability: AudioAvailability) -> some View {
        if availability == .inCloud {
            Label("In iCloud", systemImage: "icloud.and.arrow.down")
                .font(.caption)
                .foregroundColor(.orange)
        }
    }

    private var audioPickerSection: some View {
        let candidates = benchmarkCandidates
        return Section {
            if candidates.isEmpty {
                Text("No recordings between 30 s and 5 min found. Record a short voice note first.")
                    .foregroundColor(.secondary)
                    .font(.callout)
            } else {
                ForEach(candidates, id: \.note.id) { item in
                    let note = item.note
                    Button {
                        selectedNote = note
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(note.title)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                        .foregroundColor(.primary)
                                    Spacer()
                                    availabilityBadge(item.availability)
                                    Text(durationString(note.duration))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                if !note.transcription.isEmpty {
                                    Text(note.transcription)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            if selectedNote?.id == note.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.blue)
                                    .padding(.top, 1)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text("Select Recording (30 s – 5 min)")
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
                Text(isPreparingAudio
                     ? "Downloading audio from iCloud…"
                     : "First run compiles CoreML models and may take several minutes per round.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Button {
                    startBenchmark()
                } label: {
                    Text("Start Benchmark")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!canStart)
                .buttonStyle(.borderedProminent)

                if let startError {
                    Label(startError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

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
                VStack(alignment: .leading, spacing: 1) {
                    Text(round.label).font(.headline)
                    Text("Enc: \(round.encoderUnits.shortName)  Dec: \(round.decoderUnits.shortName)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
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

        startError = nil
        rounds = BenchmarkView.makeRounds()

        benchmarkTask = Task {
            UIApplication.shared.isIdleTimerDisabled = true
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            isRunning = true
            defer { isRunning = false }

            isPreparingAudio = true
            let preparedURL = await CloudStorageManager.shared.prepareFileForReading(at: note.audioFilePath)
            isPreparingAudio = false

            guard let audioURL = preparedURL else {
                if !Task.isCancelled {
                    if let candidateURL = CloudStorageManager.shared.getFileURL(for: note.audioFilePath),
                       CloudStorageManager.shared.isAudioFileMissing(at: candidateURL) {
                        startError = "This recording hasn't synced from iCloud to this device yet. Open it once to download the audio, then run the benchmark again."
                    } else {
                        startError = "Audio is still downloading from iCloud. Try again in a moment."
                    }
                }
                return
            }
            let audioPath = audioURL.path
            let audioDuration = note.duration

            for i in rounds.indices {
                if Task.isCancelled { break }
                rounds[i].status = .running

                do {
                    let computeOptions = ModelComputeOptions(
                        audioEncoderCompute: rounds[i].encoderUnits,
                        textDecoderCompute: rounds[i].decoderUnits
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
                            usePrefillPrompt: true,
                            detectLanguage: true,
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
        modelManager.encoderComputeUnits = rounds[index].encoderUnits
        modelManager.decoderComputeUnits = rounds[index].decoderUnits
    }
}

#Preview {
    NavigationView {
        BenchmarkView()
    }
}
