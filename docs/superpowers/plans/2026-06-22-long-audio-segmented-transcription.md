# Long-Audio Segmented Import Transcription — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transcribe imported audio of any length without OOM, with crash-safe resume and background continuation, never copying the imported file into iCloud.

**Architecture:** A new `@MainActor` coordinator `SegmentedAudioTranscriber` drives all imports. It writes a throwaway *working copy* of the shared file into a non-synced, backup-excluded directory, then transcribes it: files ≤30 s in a single pass (no sidecar), files >30 s sliced into ≤29 s neural-VAD segments with a JSON *sidecar* persisting progress after every segment. On completion it writes the joined text + outcome onto the `VoiceNote`, deletes the working copy and sidecar, and leaves `audioFilePath` empty (text-only note). Resume re-scans sidecars on scene activation.

**Tech Stack:** Swift, SwiftUI, SwiftData, AVFoundation, WhisperKit, Swift Testing.

## Global Constraints

- 4-space indentation; one primary type per file named after it.
- Services and SwiftUI views are `@MainActor`.
- Code comments and `// MARK:` in English. Verbose logs gated behind `#if DEBUG` with emoji prefixes (`🔍 ✅ ❌ ⚠️`).
- Unit tests use Swift Testing (`import Testing`, `@Test`, `#expect`), `@testable import Voicely`. Suites touching shared temp dirs are `@Suite(.serialized)`.
- Do **not** modify the live-recording path (`IncrementalTranscriptionCoordinator`) or `transcribeWithWhisper`'s `ChunkingStrategy.none`. Reuse existing `static` helpers only.
- Imported audio is never copied into the iCloud-synced store. Working copy + sidecar live in `Application Support/SegmentedTranscription/`, set `isExcludedFromBackup = true`, deleted on completion/cancel.
- Reuse existing types verbatim: `VoiceNoteTranscriptionOutcome` (`.transcribed`/`.noSpeech`/`.failed`), `TranscriptionOutcome` (`TranscriptionService.swift:44`), `TranscriptionResult`.
- Failed-segment placeholder text (English, app UI is English): `[M:SS–M:SS transcription unavailable]` (use `H:MM:SS` when ≥ 3600 s).
- Segment sizing reuses `IncrementalTranscriptionTiming` (target 29 s, min cut 15 s) and `IncrementalVoiceActivityCutConfiguration.default`.
- Segmentation threshold: `> 30 s` (= one WhisperKit window) gets sidecar + resume; `≤ 30 s` is a single pass, no sidecar.

---

## File Structure

- **Create** `Voicely/SegmentProgressStore.swift` — sidecar model (`SegmentedTranscriptionProgress`, `SegmentFailureRange`) + persistence + working-copy file management. One responsibility: durable on-disk state for in-flight imports.
- **Create** `Voicely/SegmentedAudioTranscriber.swift` — the offline coordinator: slice → transcribe per segment → persist → join → finalize. Depends on `TranscriptionService` and `SegmentProgressStore`.
- **Create** `VoicelyTests/SegmentedAudioTestSupport.swift` — shared test helpers (`makeSilentCAF`, `makeWorkingCopyDir`).
- **Create** `VoicelyTests/SegmentProgressStoreTests.swift`, `VoicelyTests/SegmentedAudioTranscriberTests.swift`.
- **Modify** `Voicely/ContentView.swift` — `importIncomingAudio` routes through the coordinator; add resume on `.active`.

---

## Task 1: SegmentProgressStore — model + persistence + directory

**Files:**
- Create: `Voicely/SegmentProgressStore.swift`
- Test: `VoicelyTests/SegmentProgressStoreTests.swift`

**Interfaces:**
- Produces:
  - `struct SegmentFailureRange: Codable, Equatable { var startFrame: Int64; var endFrame: Int64 }`
  - `struct SegmentedTranscriptionProgress: Codable, Equatable { var lastFrame: Int64; var totalFrames: Int64; var accumulatedText: String; var failedRanges: [SegmentFailureRange]; var updatedAt: Date }`
  - `final class SegmentProgressStore` with `init(rootDirectory: URL? = nil)`, and `@MainActor`-free methods: `load(for: UUID) -> SegmentedTranscriptionProgress?`, `save(_:for:)`, `delete(for: UUID)`, `workingCopyURL(for: UUID, fileExtension: String) -> URL`, `existingWorkingCopyURL(for: UUID) -> URL?`, `listPendingNoteIDs() -> [UUID]`, `directory: URL`.

- [ ] **Step 1: Write the failing test**

Create `VoicelyTests/SegmentProgressStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import Voicely

@Suite(.serialized)
struct SegmentProgressStoreTests {
    private func makeStore() -> SegmentProgressStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spstore_\(UUID().uuidString)")
        return SegmentProgressStore(rootDirectory: root)
    }

    @Test func saveThenLoadRoundTrips() throws {
        let store = makeStore()
        let id = UUID()
        let progress = SegmentedTranscriptionProgress(
            lastFrame: 480_000, totalFrames: 1_920_000,
            accumulatedText: "hello", failedRanges: [.init(startFrame: 0, endFrame: 16_000)],
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        store.save(progress, for: id)
        #expect(store.load(for: id) == progress)
    }

    @Test func deleteRemovesSidecar() throws {
        let store = makeStore()
        let id = UUID()
        store.save(.init(lastFrame: 1, totalFrames: 2, accumulatedText: "x",
                         failedRanges: [], updatedAt: Date()), for: id)
        store.delete(for: id)
        #expect(store.load(for: id) == nil)
    }

    @Test func listPendingReturnsSavedIDs() throws {
        let store = makeStore()
        let a = UUID(); let b = UUID()
        let p = SegmentedTranscriptionProgress(lastFrame: 0, totalFrames: 1,
                                               accumulatedText: "", failedRanges: [], updatedAt: Date())
        store.save(p, for: a); store.save(p, for: b)
        #expect(Set(store.listPendingNoteIDs()) == Set([a, b]))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Voicely -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:VoicelyTests/SegmentProgressStoreTests test`
Expected: FAIL — `cannot find 'SegmentProgressStore' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Voicely/SegmentProgressStore.swift`:

```swift
import Foundation

struct SegmentFailureRange: Codable, Equatable {
    var startFrame: Int64
    var endFrame: Int64
}

struct SegmentedTranscriptionProgress: Codable, Equatable {
    var lastFrame: Int64
    var totalFrames: Int64
    var accumulatedText: String
    var failedRanges: [SegmentFailureRange]
    var updatedAt: Date
}

/// Durable on-disk state for in-flight imported-audio transcriptions:
/// a JSON sidecar per note plus the throwaway audio working copy. Lives in a
/// non-synced, backup-excluded directory so half-done work never reaches iCloud.
final class SegmentProgressStore {
    let directory: URL
    private let fileManager = FileManager.default

    init(rootDirectory: URL? = nil) {
        let base = rootDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SegmentedTranscription", isDirectory: true)
        self.directory = base
        createDirectoryIfNeeded()
    }

    private func createDirectoryIfNeeded() {
        guard !fileManager.fileExists(atPath: directory.path) else { return }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private func sidecarURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    func load(for id: UUID) -> SegmentedTranscriptionProgress? {
        guard let data = try? Data(contentsOf: sidecarURL(for: id)) else { return nil }
        return try? JSONDecoder().decode(SegmentedTranscriptionProgress.self, from: data)
    }

    func save(_ progress: SegmentedTranscriptionProgress, for id: UUID) {
        createDirectoryIfNeeded()
        guard let data = try? JSONEncoder().encode(progress) else { return }
        try? data.write(to: sidecarURL(for: id), options: .atomic)
    }

    func delete(for id: UUID) {
        try? fileManager.removeItem(at: sidecarURL(for: id))
    }

    func workingCopyURL(for id: UUID, fileExtension: String) -> URL {
        let ext = fileExtension.isEmpty ? "audio" : fileExtension
        return directory.appendingPathComponent("\(id.uuidString).\(ext)")
    }

    func existingWorkingCopyURL(for id: UUID) -> URL? {
        let prefix = id.uuidString + "."
        let entries = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        guard let name = entries.first(where: { $0.hasPrefix(prefix) && !$0.hasSuffix(".json") })
        else { return nil }
        return directory.appendingPathComponent(name)
    }

    func listPendingNoteIDs() -> [UUID] {
        let entries = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        return entries.compactMap { name in
            guard name.hasSuffix(".json") else { return nil }
            return UUID(uuidString: String(name.dropLast(5)))
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Voicely -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:VoicelyTests/SegmentProgressStoreTests test`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Voicely/SegmentProgressStore.swift VoicelyTests/SegmentProgressStoreTests.swift
git commit -m "feat: add SegmentProgressStore for import sidecar + working copy"
```

---

## Task 2: SegmentProgressStore — import & remove working copy

**Files:**
- Modify: `Voicely/SegmentProgressStore.swift`
- Test: `VoicelyTests/SegmentProgressStoreTests.swift`

**Interfaces:**
- Consumes: `workingCopyURL(for:fileExtension:)` (Task 1).
- Produces: `func importWorkingCopy(from sourceURL: URL, for id: UUID) throws -> URL` (security-scoped copy of the shared file), `func removeWorkingCopy(for id: UUID)`.

- [ ] **Step 1: Write the failing test**

Append to `SegmentProgressStoreTests.swift`:

```swift
extension SegmentProgressStoreTests {
    @Test func importWorkingCopyCopiesBytesThenRemoveDeletes() throws {
        let store = makeStore()
        let id = UUID()
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("src_\(UUID().uuidString).m4a")
        try Data([1, 2, 3, 4]).write(to: source)

        let copy = try store.importWorkingCopy(from: source, for: id)
        #expect(FileManager.default.fileExists(atPath: copy.path))
        #expect(try Data(contentsOf: copy) == Data([1, 2, 3, 4]))
        #expect(copy.pathExtension == "m4a")

        store.removeWorkingCopy(for: id)
        #expect(store.existingWorkingCopyURL(for: id) == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Voicely -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:VoicelyTests/SegmentProgressStoreTests/importWorkingCopyCopiesBytesThenRemoveDeletes test`
Expected: FAIL — `value of type 'SegmentProgressStore' has no member 'importWorkingCopy'`.

- [ ] **Step 3: Write minimal implementation**

Add to `SegmentProgressStore`:

```swift
func importWorkingCopy(from sourceURL: URL, for id: UUID) throws -> URL {
    let accessed = sourceURL.startAccessingSecurityScopedResource()
    defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }

    createDirectoryIfNeeded()
    let destination = workingCopyURL(for: id, fileExtension: sourceURL.pathExtension)
    try? fileManager.removeItem(at: destination)

    var coordinationError: NSError?
    var copyError: Error?
    NSFileCoordinator(filePresenter: nil).coordinate(
        readingItemAt: sourceURL, options: [.withoutChanges], error: &coordinationError
    ) { readableURL in
        do { try fileManager.copyItem(at: readableURL, to: destination) }
        catch { copyError = error }
    }
    if let coordinationError { throw coordinationError }
    if let copyError { throw copyError }
    return destination
}

func removeWorkingCopy(for id: UUID) {
    if let url = existingWorkingCopyURL(for: id) {
        try? fileManager.removeItem(at: url)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Voicely -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:VoicelyTests/SegmentProgressStoreTests test`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Voicely/SegmentProgressStore.swift VoicelyTests/SegmentProgressStoreTests.swift
git commit -m "feat: import/remove non-synced working copy for imports"
```

---

## Task 3: SegmentedAudioTranscriber — skeleton + ≤30 s single pass + finalize

**Files:**
- Create: `Voicely/SegmentedAudioTranscriber.swift`
- Create: `VoicelyTests/SegmentedAudioTestSupport.swift`
- Test: `VoicelyTests/SegmentedAudioTranscriberTests.swift`

**Interfaces:**
- Consumes: `TranscriptionService.transcribeAudioOutcome(filePath:progressCallback:)`, `TranscriptionOutcome`, `SegmentProgressStore`, `VoiceNote`.
- Produces:
  - `final class SegmentedAudioTranscriber` (`@MainActor`) with `init(transcriptionService: TranscriptionService, progressStore: SegmentProgressStore, nowProvider: @escaping () -> Date = { Date() })`.
  - `var transcribeSegmentOutcome: (URL) async -> TranscriptionOutcome` (default delegates to the service; tests override).
  - `func transcribe(note: VoiceNote, sourceURL: URL) async`.
  - Internal `static func formatTimestamp(_ seconds: Double) -> String`.
- The ≤30 s path: one `transcribeSegmentOutcome` call on the whole working copy, then finalize. No sidecar.

- [ ] **Step 1: Write the shared test support, then the failing test**

Create `VoicelyTests/SegmentedAudioTestSupport.swift`:

```swift
import AVFoundation
import Foundation

enum SegmentedAudioTestSupport {
    /// Float32/16 kHz/mono silent CAF of the given length. Returns its URL.
    static func makeSilentCAF(seconds: Double) throws -> URL {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                   channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount((seconds * 16_000).rounded())
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("seg_test_\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    static func makeStore() -> SegmentProgressStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("seg_\(UUID().uuidString)")
        return SegmentProgressStore(rootDirectory: root)
    }

    @MainActor
    static func makeTranscriber(store: SegmentProgressStore,
                                service: TranscriptionService = TranscriptionService()) -> SegmentedAudioTranscriber {
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store, service: service)
        transcriber.nextCutFrame = { _, _, target in target }   // deterministic 29 s cuts in tests
        return transcriber
    }
}
```

Create `VoicelyTests/SegmentedAudioTranscriberTests.swift`:

```swift
import AVFoundation
import Foundation
import Testing
@testable import Voicely

@Suite(.serialized)
struct SegmentedAudioTranscriberTests {
    @Test @MainActor func shortFileSinglePassWritesTextAndNoSidecar() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 10)
        let store = SegmentedAudioTestSupport.makeStore()
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        transcriber.transcribeSegmentOutcome = { _ in
            .transcribed(.init(text: "hello world", duration: 1, modelIdentifier: "m"))
        }
        let note = VoiceNote(title: "imported", audioFilePath: "")

        await transcriber.transcribe(note: note, sourceURL: url)

        #expect(note.transcription == "hello world")
        #expect(note.transcriptionState == .completed)
        #expect(note.transcriptionOutcome == .transcribed)
        #expect(store.load(for: note.id) == nil)   // ≤30s never writes a sidecar
    }

    @Test func timestampFormatsMinutesAndHours() {
        #expect(SegmentedAudioTranscriber.formatTimestamp(75) == "1:15")
        #expect(SegmentedAudioTranscriber.formatTimestamp(3_661) == "1:01:01")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Voicely -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:VoicelyTests/SegmentedAudioTranscriberTests test`
Expected: FAIL — `cannot find 'SegmentedAudioTranscriber' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Voicely/SegmentedAudioTranscriber.swift`:

```swift
import AVFoundation
import Foundation

/// Drives transcription of an imported, already-complete audio file.
/// Files ≤30 s run in a single pass; longer files are sliced (Task 4).
/// The imported file is never stored in iCloud — a throwaway working copy is
/// used during transcription and removed on completion.
@MainActor
final class SegmentedAudioTranscriber {
    private let transcriptionService: TranscriptionService
    private let progressStore: SegmentProgressStore
    private let nowProvider: () -> Date

    /// Per-segment transcription. Defaults to the real service; tests override.
    var transcribeSegmentOutcome: (URL) async -> TranscriptionOutcome

    /// Chooses the end frame of the next segment within [start, target].
    /// Defaults to the neural-VAD cut; tests inject a deterministic value.
    var nextCutFrame: (URL, Int64, Int64) -> Int64 = { url, start, target in
        IncrementalTranscriptionCoordinator.voiceActivityAwareCutFrame(
            fileURL: url, startFrame: start, targetFrame: target)
    }

    /// Files longer than one WhisperKit window get sliced + a resume sidecar.
    private let singlePassFrameLimit: (Double) -> Int64 = { sampleRate in
        Int64(30.0 * sampleRate)
    }

    init(transcriptionService: TranscriptionService,
         progressStore: SegmentProgressStore,
         nowProvider: @escaping () -> Date = { Date() }) {
        self.transcriptionService = transcriptionService
        self.progressStore = progressStore
        self.nowProvider = nowProvider
        self.transcribeSegmentOutcome = { url in
            await transcriptionService.transcribeAudioOutcome(filePath: url.path)
        }
    }

    func transcribe(note: VoiceNote, sourceURL: URL) async {
        // Task 3 handles only the short single-pass case; Task 4 adds the
        // length split (and reads audio info there).
        let outcome = await transcribeSegmentOutcome(sourceURL)
        finalizeSinglePass(note: note, outcome: outcome)
        progressStore.removeWorkingCopy(for: note.id)
        progressStore.delete(for: note.id)
    }

    private func finalizeSinglePass(note: VoiceNote, outcome: TranscriptionOutcome) {
        switch outcome {
        case .transcribed(let result):
            note.transcription = result.text
            note.lastTranscriptionDuration = result.duration
            note.transcriptionModelIdentifier = result.modelIdentifier
            note.completeTranscription()
            note.transcriptionOutcome = .transcribed
        case .noSpeech:
            note.transcription = ""
            note.completeTranscription()
            note.transcriptionOutcome = .noSpeech
        case .whisperError(let diagnostic):
            note.completeTranscription()
            note.transcriptionOutcome = .failed
            note.markTranscriptionFailure(diagnostic ?? "transcription error")
        case .modelUnavailable, .audioUnavailable, .cancelled:
            note.completeTranscription()
            note.transcriptionOutcome = .failed
            note.markTranscriptionFailure("model or audio unavailable")
        }
        note.clearTransientTranscriptionFlags()
    }

    // MARK: - Audio info

    struct AudioInfo { let totalFrames: Int64; let sampleRate: Double }

    nonisolated static func readAudioInfo(_ url: URL) -> AudioInfo? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        return AudioInfo(totalFrames: file.length,
                         sampleRate: file.processingFormat.sampleRate)
    }

    nonisolated static func formatTimestamp(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let s = total % 60, m = (total / 60) % 60, h = total / 3600
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Voicely -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:VoicelyTests/SegmentedAudioTranscriberTests test`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Voicely/SegmentedAudioTranscriber.swift VoicelyTests/SegmentedAudioTestSupport.swift VoicelyTests/SegmentedAudioTranscriberTests.swift
git commit -m "feat: SegmentedAudioTranscriber skeleton + short-file single pass"
```

---

## Task 4: Long-file segmentation loop + per-segment sidecar

**Files:**
- Modify: `Voicely/SegmentedAudioTranscriber.swift`
- Test: `VoicelyTests/SegmentedAudioTranscriberTests.swift`

**Interfaces:**
- Consumes: `IncrementalTranscriptionCoordinator.extractSegment(fileURL:from:to:segmentIndex:)`, `voiceActivityAwareCutFrame(...)`, `IncrementalTranscriptionTiming.defaultIntervalSeconds`, `SegmentProgressStore.save(_:for:)`.
- Produces: long-file branch inside `transcribe(note:sourceURL:)` that loops segments (using the injectable `nextCutFrame: (URL, Int64, Int64) -> Int64`, default = neural-VAD cut), joins text with `"\n"`, and saves a sidecar after each segment.

- [ ] **Step 1: Write the failing test**

Append to `SegmentedAudioTranscriberTests.swift`:

```swift
extension SegmentedAudioTranscriberTests {
    @Test @MainActor func longFileSlicesAndJoinsWithSidecar() async throws {
        // 70 s @ 16 kHz, target 29 s ⇒ 3 segments (29 + 29 + 12).
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 70)
        let store = SegmentedAudioTestSupport.makeStore()
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        let calls = Counter()
        transcriber.transcribeSegmentOutcome = { _ in
            await calls.increment()
            return .transcribed(.init(text: "seg", duration: 1, modelIdentifier: "m"))
        }
        let note = VoiceNote(title: "imported", audioFilePath: "")

        await transcriber.transcribe(note: note, sourceURL: url)

        #expect(await calls.value == 3)
        #expect(note.transcription == "seg\nseg\nseg")
        #expect(note.transcriptionOutcome == .transcribed)
    }
}

actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Voicely -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:VoicelyTests/SegmentedAudioTranscriberTests/longFileSlicesAndJoinsWithSidecar test`
Expected: FAIL — only 1 call (short-file path still runs), `calls.value == 1`.

- [ ] **Step 3: Write minimal implementation**

In `transcribe(note:sourceURL:)`, replace the body after `readAudioInfo` with a length branch:

```swift
    func transcribe(note: VoiceNote, sourceURL: URL) async {
        guard let info = Self.readAudioInfo(sourceURL) else {
            note.completeTranscription()
            note.transcriptionOutcome = .failed
            note.markTranscriptionFailure("could not read imported audio")
            progressStore.removeWorkingCopy(for: note.id)
            return
        }

        if info.totalFrames <= singlePassFrameLimit(info.sampleRate) {
            let outcome = await transcribeSegmentOutcome(sourceURL)
            finalizeSinglePass(note: note, outcome: outcome)
        } else {
            await transcribeSegmented(note: note, sourceURL: sourceURL, info: info)
        }
        progressStore.removeWorkingCopy(for: note.id)
        progressStore.delete(for: note.id)
    }

    private func transcribeSegmented(note: VoiceNote, sourceURL: URL, info: AudioInfo) async {
        let noteID = note.id
        let batchFrames = Int64(Double(IncrementalTranscriptionTiming.defaultIntervalSeconds) * info.sampleRate)
        var start: Int64 = 0
        var pieces: [String] = []
        var segmentIndex = 0

        while start < info.totalFrames {
            let targetFrame = min(start + batchFrames, info.totalFrames)
            let isLastBatch = targetFrame >= info.totalFrames
            var end = targetFrame
            if !isLastBatch {
                let cut = nextCutFrame(sourceURL, start, targetFrame)
                if cut > start { end = cut }
            }

            segmentIndex += 1
            let captured = segmentIndex
            guard let segmentURL = await Task.detached(priority: .utility, operation: {
                IncrementalTranscriptionCoordinator.extractSegment(
                    fileURL: sourceURL, from: start, to: end, segmentIndex: captured)
            }).value else {
                start = end
                continue
            }

            let outcome = await transcribeSegmentOutcome(segmentURL)
            try? FileManager.default.removeItem(at: segmentURL)

            if case .transcribed(let result) = outcome,
               let text = IncrementalTranscriptionCoordinator.sanitizedSegmentText(result.text) {
                pieces.append(text)
            }

            start = end
            progressStore.save(.init(lastFrame: start, totalFrames: info.totalFrames,
                                     accumulatedText: pieces.joined(separator: "\n"),
                                     failedRanges: [], updatedAt: nowProvider()), for: noteID)
        }

        note.transcription = pieces.joined(separator: "\n")
        note.completeTranscription()
        note.transcriptionOutcome = .transcribed
        note.clearTransientTranscriptionFlags()
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Voicely -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:VoicelyTests/SegmentedAudioTranscriberTests test`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Voicely/SegmentedAudioTranscriber.swift VoicelyTests/SegmentedAudioTranscriberTests.swift
git commit -m "feat: long-file segmentation loop with per-segment sidecar"
```

---

## Task 5: Resume from sidecar

**Files:**
- Modify: `Voicely/SegmentedAudioTranscriber.swift`
- Test: `VoicelyTests/SegmentedAudioTranscriberTests.swift`

**Interfaces:**
- Consumes: `SegmentProgressStore.load(for:)`.
- Produces: `transcribeSegmented` starts at the saved `lastFrame` and seeds `pieces` from `accumulatedText`; `func resumePending(notes: [VoiceNote]) async` re-drives notes that have a sidecar + a surviving working copy.

- [ ] **Step 1: Write the failing test**

Append to `SegmentedAudioTranscriberTests.swift`:

```swift
extension SegmentedAudioTranscriberTests {
    @Test @MainActor func resumeStartsFromSavedFrame() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 70)  // 3 segments fresh
        let store = SegmentedAudioTestSupport.makeStore()
        let note = VoiceNote(title: "imported", audioFilePath: "")
        // Pretend segment 1 already finished: lastFrame at 29 s, one piece saved.
        store.save(.init(lastFrame: Int64(29 * 16_000), totalFrames: Int64(70 * 16_000),
                         accumulatedText: "first", failedRanges: [], updatedAt: Date()),
                   for: note.id)

        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        let calls = Counter()
        transcriber.transcribeSegmentOutcome = { _ in
            await calls.increment()
            return .transcribed(.init(text: "more", duration: 1, modelIdentifier: "m"))
        }

        await transcriber.transcribe(note: note, sourceURL: url)

        #expect(await calls.value == 2)               // only the remaining 2 segments
        #expect(note.transcription == "first\nmore\nmore")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Voicely -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:VoicelyTests/SegmentedAudioTranscriberTests/resumeStartsFromSavedFrame test`
Expected: FAIL — `calls.value == 3` and text starts re-transcribing from 0.

- [ ] **Step 3: Write minimal implementation**

In `transcribeSegmented`, seed from the sidecar before the loop:

```swift
    private func transcribeSegmented(note: VoiceNote, sourceURL: URL, info: AudioInfo) async {
        let noteID = note.id
        let batchFrames = Int64(Double(IncrementalTranscriptionTiming.defaultIntervalSeconds) * info.sampleRate)
        let resumed = progressStore.load(for: noteID)
        var start: Int64 = resumed?.lastFrame ?? 0
        var pieces: [String] = (resumed?.accumulatedText).flatMap { $0.isEmpty ? [] : [$0] } ?? []
        var segmentIndex = 0
        // ... loop body unchanged from Task 4 ...
```

Add `resumePending` after `transcribe(note:sourceURL:)`:

```swift
    /// Re-drive imports that have a sidecar and a surviving working copy
    /// (e.g. after the app was suspended or killed mid-transcription).
    func resumePending(notes: [VoiceNote]) async {
        let byID = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        for id in progressStore.listPendingNoteIDs() {
            guard let note = byID[id],
                  let workingCopy = progressStore.existingWorkingCopyURL(for: id) else {
                progressStore.delete(for: id)            // orphan: note gone — clean up
                continue
            }
            await transcribe(note: note, sourceURL: workingCopy)
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Voicely -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:VoicelyTests/SegmentedAudioTranscriberTests test`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Voicely/SegmentedAudioTranscriber.swift VoicelyTests/SegmentedAudioTranscriberTests.swift
git commit -m "feat: resume segmented transcription from sidecar"
```

---

## Task 6: Per-segment retry, failed-range skip + placeholder, all-noSpeech outcome

**Files:**
- Modify: `Voicely/SegmentedAudioTranscriber.swift`
- Test: `VoicelyTests/SegmentedAudioTranscriberTests.swift`

**Interfaces:**
- Produces: a segment failing twice records a `SegmentFailureRange`, inserts an `[M:SS–M:SS transcription unavailable]` placeholder at that position, and continues; final outcome is `.failed` if any range failed, `.noSpeech` if every segment was noSpeech, else `.transcribed`.

- [ ] **Step 1: Write the failing test**

Append to `SegmentedAudioTranscriberTests.swift`:

```swift
extension SegmentedAudioTranscriberTests {
    @Test @MainActor func failedSegmentRetriesThenSkipsWithPlaceholder() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 70)  // 3 segments
        let store = SegmentedAudioTestSupport.makeStore()
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        let calls = Counter()
        transcriber.transcribeSegmentOutcome = { _ in
            let n = await calls.incrementAndGet()
            // Segment 2 = calls 2,3,4 (initial + 2 retries) all fail; others succeed.
            if (2...4).contains(n) { return .whisperError("boom") }
            return .transcribed(.init(text: "ok", duration: 1, modelIdentifier: "m"))
        }
        let note = VoiceNote(title: "imported", audioFilePath: "")

        await transcriber.transcribe(note: note, sourceURL: url)

        #expect(await calls.value == 5)               // seg1(1) + seg2(3) + seg3(1)
        #expect(note.transcriptionOutcome == .failed)
        #expect(note.transcription.contains("transcription unavailable"))
        #expect(note.transcription.hasPrefix("ok"))
        #expect(note.transcription.hasSuffix("ok"))
    }

    @Test @MainActor func allNoSpeechYieldsNoSpeechOutcome() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 70)
        let store = SegmentedAudioTestSupport.makeStore()
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        transcriber.transcribeSegmentOutcome = { _ in .noSpeech }
        let note = VoiceNote(title: "imported", audioFilePath: "")

        await transcriber.transcribe(note: note, sourceURL: url)

        #expect(note.transcriptionOutcome == .noSpeech)
        #expect(note.transcription.isEmpty)
    }
}

extension Counter {
    func incrementAndGet() -> Int { value += 1; return value }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Voicely -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:VoicelyTests/SegmentedAudioTranscriberTests test`
Expected: FAIL — no retry/placeholder logic; failing segment is silently dropped, outcome `.transcribed`.

- [ ] **Step 3: Write minimal implementation**

Replace the loop body inside `transcribeSegmented` (the part from `let outcome = await transcribeSegmentOutcome(segmentURL)` through the sidecar `save`) and the finalization with failure tracking:

```swift
            var outcome = await transcribeSegmentOutcome(segmentURL)
            var retries = 0
            while case .whisperError = outcome, retries < 2 {
                retries += 1
                outcome = await transcribeSegmentOutcome(segmentURL)
            }
            try? FileManager.default.removeItem(at: segmentURL)

            switch outcome {
            case .transcribed(let result):
                if let text = IncrementalTranscriptionCoordinator.sanitizedSegmentText(result.text) {
                    pieces.append(text)
                }
                producedAnyText = true
            case .noSpeech:
                break  // silence in this slice — contributes nothing, not an error
            case .whisperError, .modelUnavailable, .audioUnavailable, .cancelled:
                let range = SegmentFailureRange(startFrame: start, endFrame: end)
                failedRanges.append(range)
                pieces.append(Self.placeholder(forStart: start, end: end, sampleRate: info.sampleRate))
            }

            start = end
            progressStore.save(.init(lastFrame: start, totalFrames: info.totalFrames,
                                     accumulatedText: pieces.joined(separator: "\n"),
                                     failedRanges: failedRanges, updatedAt: nowProvider()), for: noteID)
        }

        note.transcription = pieces.joined(separator: "\n")
        note.completeTranscription()
        if !failedRanges.isEmpty {
            note.transcriptionOutcome = .failed
            note.markTranscriptionFailure("\(failedRanges.count) segment(s) failed after retry")
        } else if !producedAnyText {
            note.transcriptionOutcome = .noSpeech
        } else {
            note.transcriptionOutcome = .transcribed
        }
        note.clearTransientTranscriptionFlags()
    }
```

Add the two new locals near the top of `transcribeSegmented` (alongside `pieces`), seeding failures from the sidecar:

```swift
        var failedRanges: [SegmentFailureRange] = resumed?.failedRanges ?? []
        var producedAnyText = !pieces.isEmpty
```

Add the placeholder helper:

```swift
    nonisolated static func placeholder(forStart start: Int64, end: Int64, sampleRate: Double) -> String {
        let from = formatTimestamp(Double(start) / sampleRate)
        let to = formatTimestamp(Double(end) / sampleRate)
        return "[\(from)–\(to) transcription unavailable]"
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Voicely -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:VoicelyTests/SegmentedAudioTranscriberTests test`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Voicely/SegmentedAudioTranscriber.swift VoicelyTests/SegmentedAudioTranscriberTests.swift
git commit -m "feat: per-segment retry, failed-range placeholder, noSpeech outcome"
```

---

## Task 7: Claim note + lease heartbeat per segment

**Files:**
- Modify: `Voicely/SegmentedAudioTranscriber.swift`
- Test: `VoicelyTests/SegmentedAudioTranscriberTests.swift`

**Interfaces:**
- Consumes: `VoiceNote.claimTranscription(ownerDeviceID:attemptID:queuedAt:leaseExpiresAt:)`, `TranscriptionService.deviceIDProvider`, `TranscriptionService.leaseDuration`.
- Produces: `transcribe(note:sourceURL:)` claims the note (state `.claimed`, owner = this device) before work; each saved sidecar also renews `transcriptionLeaseExpiresAt` (segment completion acts as the heartbeat).

- [ ] **Step 1: Write the failing test**

Append to `SegmentedAudioTranscriberTests.swift`:

```swift
extension SegmentedAudioTranscriberTests {
    @Test @MainActor func claimsNoteWithThisDeviceBeforeWorking() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 70)
        let store = SegmentedAudioTestSupport.makeStore()
        let service = TranscriptionService()
        service.deviceIDProvider = { "device-X" }
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store, service: service)
        var sawClaimedOwner: String?
        transcriber.transcribeSegmentOutcome = { _ in
            sawClaimedOwner = sawClaimedOwner ?? "captured"
            return .transcribed(.init(text: "x", duration: 1, modelIdentifier: "m"))
        }
        let note = VoiceNote(title: "imported", audioFilePath: "")

        await transcriber.transcribe(note: note, sourceURL: url)

        // After completion ownership is cleared, but the lease was set while claimed.
        #expect(sawClaimedOwner == "captured")
        #expect(note.transcriptionState == .completed)
    }

    @Test @MainActor func claimsBeforeFirstSegmentCall() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 70)
        let store = SegmentedAudioTestSupport.makeStore()
        let service = TranscriptionService()
        service.deviceIDProvider = { "device-X" }
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store, service: service)
        let note = VoiceNote(title: "imported", audioFilePath: "")
        var ownerAtFirstCall: String?
        transcriber.transcribeSegmentOutcome = { _ in
            ownerAtFirstCall = ownerAtFirstCall ?? note.transcriptionOwnerDeviceID
            return .transcribed(.init(text: "x", duration: 1, modelIdentifier: "m"))
        }

        await transcriber.transcribe(note: note, sourceURL: url)
        #expect(ownerAtFirstCall == "device-X")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Voicely -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:VoicelyTests/SegmentedAudioTranscriberTests/claimsBeforeFirstSegmentCall test`
Expected: FAIL — `ownerAtFirstCall == nil` (note never claimed).

- [ ] **Step 3: Write minimal implementation**

At the top of `transcribe(note:sourceURL:)`, right after the `readAudioInfo` guard succeeds, claim the note:

```swift
        let now = nowProvider()
        note.claimTranscription(
            ownerDeviceID: transcriptionService.deviceIDProvider(),
            attemptID: UUID().uuidString,
            queuedAt: note.transcriptionQueuedAt ?? now,
            leaseExpiresAt: now.addingTimeInterval(transcriptionService.leaseDuration))
        note.clearTransientTranscriptionFlags()
```

In `transcribeSegmented`, after each `progressStore.save(...)`, renew the lease:

```swift
            note.transcriptionLeaseExpiresAt = nowProvider().addingTimeInterval(transcriptionService.leaseDuration)
```

(`note` is already captured by `transcribeSegmented`; this runs on the MainActor.)

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Voicely -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:VoicelyTests/SegmentedAudioTranscriberTests test`
Expected: PASS (9 tests).

- [ ] **Step 5: Commit**

```bash
git add Voicely/SegmentedAudioTranscriber.swift VoicelyTests/SegmentedAudioTranscriberTests.swift
git commit -m "feat: claim note + per-segment lease renewal for imports"
```

---

## Task 8: Background continuation (stop cleanly at a segment boundary)

**Files:**
- Modify: `Voicely/SegmentedAudioTranscriber.swift`
- Test: `VoicelyTests/SegmentedAudioTranscriberTests.swift`

**Interfaces:**
- Produces: `var shouldStopForBackground: () -> Bool` (default `{ false }`; production wires it to a `beginBackgroundTask` expiration flag). When it returns `true`, the segment loop stops at the current boundary leaving the sidecar intact (note stays `.claimed`, not finalized) so `resumePending` continues later.

- [ ] **Step 1: Write the failing test**

Append to `SegmentedAudioTranscriberTests.swift`:

```swift
extension SegmentedAudioTranscriberTests {
    @Test @MainActor func stopsAtBoundaryWhenBackgroundExpires() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 70)  // 3 segments
        let store = SegmentedAudioTestSupport.makeStore()
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        let calls = Counter()
        transcriber.transcribeSegmentOutcome = { _ in
            _ = await calls.incrementAndGet()
            return .transcribed(.init(text: "seg", duration: 1, modelIdentifier: "m"))
        }
        // Stop after the first segment has been persisted.
        transcriber.shouldStopForBackground = { /* read after */ false }
        let note = VoiceNote(title: "imported", audioFilePath: "")
        transcriber.shouldStopForBackground = {
            // True once one segment is done.
            store.load(for: note.id)?.lastFrame ?? 0 > 0
        }

        await transcriber.transcribe(note: note, sourceURL: url)

        #expect(await calls.value == 1)                       // stopped after segment 1
        #expect(note.transcriptionState == .claimed)          // not finalized
        #expect(store.load(for: note.id)?.lastFrame ?? 0 > 0) // sidecar kept for resume
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Voicely -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:VoicelyTests/SegmentedAudioTranscriberTests/stopsAtBoundaryWhenBackgroundExpires test`
Expected: FAIL — runs all 3 segments and finalizes.

- [ ] **Step 3: Write minimal implementation**

Add the property:

```swift
    /// When true, the segment loop stops at the next boundary, leaving the
    /// sidecar intact for later resume. Wired to background-time expiration.
    var shouldStopForBackground: () -> Bool = { false }
```

At the top of the `while start < info.totalFrames` loop in `transcribeSegmented`:

```swift
            if shouldStopForBackground() { return }   // sidecar already persisted; resume later
```

Guard the working-copy/sidecar cleanup in `transcribe(note:sourceURL:)` so a backgrounded run keeps them:

```swift
        } else {
            await transcribeSegmented(note: note, sourceURL: sourceURL, info: info)
            if note.transcriptionState != .completed { return }  // backgrounded: keep copy + sidecar
        }
        progressStore.removeWorkingCopy(for: note.id)
        progressStore.delete(for: note.id)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Voicely -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:VoicelyTests/SegmentedAudioTranscriberTests test`
Expected: PASS (10 tests).

- [ ] **Step 5: Commit**

```bash
git add Voicely/SegmentedAudioTranscriber.swift VoicelyTests/SegmentedAudioTranscriberTests.swift
git commit -m "feat: stop segmentation at boundary on background expiration"
```

---

## Task 9: Wire imports through the coordinator (no iCloud copy)

**Files:**
- Modify: `Voicely/ContentView.swift:643-676` (`importIncomingAudio`)
- Test: manual (UI path; logic covered by Tasks 1–8)

**Interfaces:**
- Consumes: `SegmentProgressStore.importWorkingCopy(from:for:)`, `SegmentedAudioTranscriber.transcribe(note:sourceURL:)`, `CloudStorageManager.isSupportedImportedAudioURL`.
- Produces: imported notes have `audioFilePath = ""` (text-only; player auto-hidden via existing `shouldShowAudioPlayerCard`), the source is copied only to the non-synced working copy, and transcription runs through the coordinator.

- [ ] **Step 1: Add stored coordinator + store to ContentView**

Near the other `ContentView` state (where `transcriptionService`/`cloudManager` are declared), add:

```swift
    @State private var segmentProgressStore = SegmentProgressStore()
    @State private var segmentedTranscriber: SegmentedAudioTranscriber?
```

Add a lazy accessor (place beside `importIncomingAudio`):

```swift
    private func makeSegmentedTranscriber() -> SegmentedAudioTranscriber {
        if let existing = segmentedTranscriber { return existing }
        let created = SegmentedAudioTranscriber(
            transcriptionService: transcriptionService, progressStore: segmentProgressStore)
        segmentedTranscriber = created
        return created
    }
```

- [ ] **Step 2: Replace `importIncomingAudio` body**

Replace `importIncomingAudio(from:)` (`ContentView.swift:643-676`) with:

```swift
    private func importIncomingAudio(from url: URL) async {
        transcriptionService.setModelManager(modelManager)
        guard CloudStorageManager.isSupportedImportedAudioURL(url) else {
            inboundAudioImportError = "Unsupported audio file type."
            return
        }
        do {
            let title = url.deletingPathExtension().lastPathComponent
            let note = VoiceNote(title: title.isEmpty ? "Imported Audio" : title, audioFilePath: "")
            note.titleWasManuallyEdited = true

            // Copy only to the non-synced working copy — never into the iCloud store.
            let workingCopy = try segmentProgressStore.importWorkingCopy(from: url, for: note.id)
            note.duration = await audioDuration(for: workingCopy)

            modelContext.insert(note)
            try modelContext.save()
            selectedNoteID = note.id

            if !transcriptionService.isWhisperAvailable() {
                _ = await transcriptionService.loadWhisperModel()
            }
            guard transcriptionService.isWhisperAvailable() else { return }
            await makeSegmentedTranscriber().transcribe(note: note, sourceURL: workingCopy)
        } catch {
            inboundAudioImportError = error.localizedDescription
        }
    }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild -scheme Voicely -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Run the full unit suite (no regressions)**

Run: `xcodebuild -scheme Voicely -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:VoicelyTests test`
Expected: PASS (all suites).

- [ ] **Step 5: Commit**

```bash
git add Voicely/ContentView.swift
git commit -m "feat: route imports through segmented transcriber, no iCloud copy"
```

---

## Task 10: Resume on scene activation + background task wiring

**Files:**
- Modify: `Voicely/ContentView.swift` (scenePhase observer + background task)

**Interfaces:**
- Consumes: `SegmentedAudioTranscriber.resumePending(notes:)`, `shouldStopForBackground`.
- Produces: on `.active`, pending imports resume; during a run, a `beginBackgroundTask` buys time and its expiration flips `shouldStopForBackground`.

- [ ] **Step 1: Add scenePhase + a resume hook**

In `ContentView`, add the environment value (near other `@Environment` declarations):

```swift
    @Environment(\.scenePhase) private var scenePhase
```

Add a `@Query` for resume (if ContentView already has a notes `@Query`, reuse it instead) and a resume method:

```swift
    private func resumePendingImports() {
        let store = segmentProgressStore
        guard !store.listPendingNoteIDs().isEmpty else { return }
        Task { await makeSegmentedTranscriber().resumePending(notes: notes) }
    }
```

> `notes` is the existing `@Query private var notes: [VoiceNote]` in ContentView. If the property has a different name, pass that array.

- [ ] **Step 2: Observe scenePhase on the main view**

Attach to ContentView's top-level view (next to existing `.onOpenURL`):

```swift
        .onChange(of: scenePhase) { _, newValue in
            guard newValue == .active, !AppRuntime.isRunningTests else { return }
            resumePendingImports()
        }
```

- [ ] **Step 3: Wrap a run with a background task**

Add a helper in `ContentView` and use it inside `importIncomingAudio` / `resumePending` calls so a suspended app stops cleanly:

```swift
    @MainActor
    private func withBackgroundTask(_ work: @escaping (SegmentedAudioTranscriber) async -> Void) async {
        let transcriber = makeSegmentedTranscriber()
        #if canImport(UIKit)
        var expired = false
        transcriber.shouldStopForBackground = { expired }
        let taskID = UIApplication.shared.beginBackgroundTask {
            expired = true
        }
        await work(transcriber)
        transcriber.shouldStopForBackground = { false }
        if taskID != .invalid { UIApplication.shared.endBackgroundTask(taskID) }
        #else
        await work(transcriber)
        #endif
    }
```

Then change the two call sites to route through it:
- In `importIncomingAudio`, replace `await makeSegmentedTranscriber().transcribe(note: note, sourceURL: workingCopy)` with:

```swift
            await withBackgroundTask { await $0.transcribe(note: note, sourceURL: workingCopy) }
```

- In `resumePendingImports`, replace the `Task { ... }` body with:

```swift
        Task { await withBackgroundTask { await $0.resumePending(notes: notes) } }
```

Add `import UIKit` at the top of `ContentView.swift` if not already present (it is, via SwiftUI on Catalyst/iOS, but add an explicit `#if canImport(UIKit) import UIKit #endif` if the build complains).

- [ ] **Step 4: Build for both platforms**

Run: `xcodebuild -scheme Voicely -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' build`
Then: `xcodebuild -scheme Voicely -configuration Debug -destination 'platform=macOS,variant=Mac Catalyst' build`
Expected: BUILD SUCCEEDED for both.

- [ ] **Step 5: Commit**

```bash
git add Voicely/ContentView.swift
git commit -m "feat: resume pending imports on activation + background task"
```

---

## Self-Review Notes (for the implementer)

- **Spec coverage:** 30 s split (Task 3/4), 15–29 s neural-VAD slices reusing existing statics (Task 4), sidecar resume (Task 5), retry/skip/placeholder + noSpeech (Task 6), claim+lease (Task 7), background (Task 8), no-iCloud working copy + text-only note (Tasks 2/9), resume on activation (Task 10).
- **Manual verification after Task 10:** Share a >1 h recording from Voice Memos → Voicely; confirm progress advances, backgrounding then reopening resumes (sidecar `lastFrame` grows, no restart), the finished note shows text with no player control, and the working copy + sidecar under `Application Support/SegmentedTranscription/` are gone.
- **Known follow-ups (out of scope):** verify `extractSegment` handles every imported container (mp3/m4a) — transcode to PCM if a format can't be frame-read; tune placeholder copy with the outcome-handling UI spec.
