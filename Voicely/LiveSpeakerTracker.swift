import AVFoundation
import FluidAudio
import Foundation

/// What live speaker detection knows about a recording so far.
struct LiveSpeakerSnapshot: Sendable, Equatable {
    /// Seconds from the start of the recording the speaker model has judged.
    var coveredSeconds: Double = 0
    /// Who spoke when, including turns still running at `coveredSeconds`.
    var ranges: [SpeakerTimeRange] = []
    /// Where one speaker's turn hands over to another's, in recording seconds.
    /// A change is listed only once both turns around it are long enough to
    /// count, so later audio never moves or removes it.
    var turnChanges: [TimeInterval] = []
}

/// Follows the speakers of a recording while it is written.
protocol LiveSpeakerTracking: AnyObject, Sendable {
    /// Judges the recording up to `frame`, a frame count of the recording file.
    func advance(toFrame frame: AVAudioFramePosition) async throws -> LiveSpeakerSnapshot
    /// Judges the rest of the recording up to `frame` and frees the model.
    func finish(atFrame frame: AVAudioFramePosition) async throws -> LiveSpeakerSnapshot
}

/// Runs Nemotron 3 over the 16 kHz recording file as it grows. The model keeps
/// its speaker state for the whole recording, so speaker numbers stay stable.
actor NemotronLiveSpeakerTracker: LiveSpeakerTracking {
    enum TrackerError: LocalizedError {
        case unsupportedAudioFormat
        case finished

        var errorDescription: String? {
            switch self {
            case .unsupportedAudioFormat: "Live speaker detection needs 16 kHz recording audio."
            case .finished: "Live speaker detection has already finished."
            }
        }
    }

    private let fileURL: URL
    private let modelDirectory: URL
    private var diarizer: Nemotron3Diarizer?
    private var timeline: SpeakerTurnTimeline?
    private var readFrame: AVAudioFramePosition = 0
    private var isFinished = false

    /// Nil when this build carries no speaker model.
    init?(fileURL: URL) {
        guard let directory = SpeakerDiarizationEngine.bundledModelDirectory() else { return nil }
        self.fileURL = fileURL
        self.modelDirectory = directory
    }

    func advance(toFrame frame: AVAudioFramePosition) async throws -> LiveSpeakerSnapshot {
        guard !isFinished else { throw TrackerError.finished }
        let diarizer = try await loadedDiarizer()
        try read(upTo: frame, into: diarizer)
        return timeline?.snapshot() ?? LiveSpeakerSnapshot()
    }

    func finish(atFrame frame: AVAudioFramePosition) async throws -> LiveSpeakerSnapshot {
        guard !isFinished else { return timeline?.snapshot() ?? LiveSpeakerSnapshot() }
        let diarizer = try await loadedDiarizer()
        try read(upTo: frame, into: diarizer)
        try timeline?.append(diarizer.finishStream())
        isFinished = true
        // Free the model as soon as the recording no longer needs it.
        self.diarizer = nil
        return timeline?.snapshot() ?? LiveSpeakerSnapshot()
    }

    private func loadedDiarizer() async throws -> Nemotron3Diarizer {
        if let diarizer { return diarizer }
        // A call that arrives while the model is loading waits for that load
        // instead of starting a second copy.
        let loading = self.loading ?? Task { try await self.loadModel() }
        self.loading = loading
        try await loading.value
        guard let diarizer else { throw TrackerError.finished }
        return diarizer
    }

    private var loading: Task<Void, Error>?

    private func loadModel() async throws {
        let (config, models) = try await SpeakerDiarizationEngine.loadModels(from: modelDirectory)
        diarizer = Nemotron3Diarizer(config: config, models: models)
        timeline = SpeakerTurnTimeline(speakerCount: config.numSpeakers)
    }

    private func read(upTo frame: AVAudioFramePosition, into diarizer: Nemotron3Diarizer) throws {
        guard frame > readFrame else { return }
        let file = try AVAudioFile(forReading: fileURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard format.sampleRate == 16_000 else { throw TrackerError.unsupportedAudioFormat }
        let end = min(frame, file.length)
        while readFrame < end {
            try Task.checkCancellation()
            let count = AVAudioFrameCount(min(end - readFrame, 32_000))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else {
                throw TrackerError.unsupportedAudioFormat
            }
            file.framePosition = readFrame
            try file.read(into: buffer, frameCount: count)
            guard buffer.frameLength > 0 else { break }
            let mono = format.channelCount == 1 ? buffer : AudioRecordingService.mixedDownToMono(buffer)
            guard let data = mono?.floatChannelData?[0] else { throw TrackerError.unsupportedAudioFormat }
            diarizer.appendAudio(Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength))))
            readFrame += AVAudioFramePosition(buffer.frameLength)
            let results = try autoreleasepool { try diarizer.processBufferedAudio() }
            try timeline?.append(results)
        }
    }
}

/// Waits for speaker model work only so long. A Core ML load that never
/// returns cannot be stopped from outside, so on expiry the work is cancelled
/// and left to end on its own, and its result is dropped.
enum SpeakerModelDeadline {
    struct Expired: Error {}

    static func run<T: Sendable>(seconds: Double,
                                 _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let race = Race<T>()
        return try await withCheckedThrowingContinuation { continuation in
            race.begin(
                continuation,
                work: Task {
                    do {
                        race.end(with: .success(try await operation()))
                    } catch {
                        race.end(with: .failure(error))
                    }
                },
                timer: Task {
                    try? await Task.sleep(for: .seconds(seconds))
                    guard !Task.isCancelled else { return }
                    race.end(with: .failure(Expired()))
                })
        }
    }

    /// Resumes the caller once, with whichever of the work or the timer ends first.
    private final class Race<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var result: Result<T, Error>?
        private var work: Task<Void, Never>?
        private var timer: Task<Void, Never>?

        func begin(_ continuation: CheckedContinuation<T, Error>, work: Task<Void, Never>, timer: Task<Void, Never>) {
            lock.lock()
            if let result {
                lock.unlock()
                timer.cancel()
                continuation.resume(with: result)
                return
            }
            self.continuation = continuation
            self.work = work
            self.timer = timer
            lock.unlock()
        }

        func end(with outcome: Result<T, Error>) {
            lock.lock()
            guard result == nil else { lock.unlock(); return }
            result = outcome
            let continuation = self.continuation
            self.continuation = nil
            let work = self.work, timer = self.timer
            lock.unlock()
            timer?.cancel()
            if case .failure(let error) = outcome, error is Expired { work?.cancel() }
            continuation?.resume(with: outcome)
        }
    }
}

/// Turns Nemotron's 10 ms speaker probabilities into ranges and turn changes
/// without keeping the frame matrix of a long recording.
struct SpeakerTurnTimeline {
    struct Turn: Equatable {
        var speaker: Int
        var startFrame: Int
        var endFrame: Int
    }

    /// A dominant speaker must hold the floor this long (20 frames = 0.2 s)
    /// for a run to count, as in the measurements behind cutting at turns.
    static let minimumRunFrames = 20

    private let speakerCount: Int
    private var activity: SpeakerActivitySegments
    private(set) var frameCount = 0
    private(set) var turns: [Turn] = []
    private var runSpeaker = -1
    private var runStart = 0

    init(speakerCount: Int) {
        self.speakerCount = speakerCount
        activity = SpeakerActivitySegments(speakerCount: speakerCount)
    }

    mutating func append(_ chunks: [Nemotron3ChunkResult]) throws {
        for chunk in chunks {
            try append(probabilities: chunk.probabilities, frameCount: chunk.frameCount)
        }
    }

    mutating func append(probabilities: [Float], frameCount count: Int) throws {
        try activity.append(probabilities: probabilities, frameCount: count)
        for frame in 0..<count {
            var best = -1
            var bestProbability: Float = 0.5
            for speaker in 0..<speakerCount {
                let probability = probabilities[frame * speakerCount + speaker]
                if probability > bestProbability {
                    best = speaker
                    bestProbability = probability
                }
            }
            if best != runSpeaker {
                closeRun(at: frameCount)
                runSpeaker = best
                runStart = frameCount
            }
            frameCount += 1
        }
    }

    func snapshot() -> LiveSpeakerSnapshot {
        var copy = self
        copy.closeRun(at: frameCount)
        let changes = zip(copy.turns, copy.turns.dropFirst()).map { previous, next in
            let frame = next.startFrame > previous.endFrame
                ? Double(previous.endFrame + next.startFrame) / 2
                : Double(next.startFrame)
            return frame / 100
        }
        let covered = Double(frameCount) / 100
        return LiveSpeakerSnapshot(
            coveredSeconds: covered,
            ranges: activity.snapshot(duration: covered),
            turnChanges: changes
        )
    }

    private mutating func closeRun(at end: Int) {
        guard runSpeaker >= 0, end - runStart >= Self.minimumRunFrames else { return }
        if let last = turns.last, last.speaker == runSpeaker {
            turns[turns.count - 1].endFrame = end
        } else {
            turns.append(Turn(speaker: runSpeaker, startFrame: runStart, endFrame: end))
        }
    }
}
