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
        let configuration = TranscriptionRunConfiguration(
            engineMode: .qwen3ASR,
            modelIdentifier: Qwen3ASRDefaults.modelId,
            selectedLanguageKey: "auto",
            prompt: nil,
            chunkSeconds: 14,
            singlePassSecondsLimit: 15,
            minimumChunkCutSeconds: 7,
            timingGranularity: .segment
        )
        let progress = SegmentedTranscriptionProgress(
            lastFrame: 480_000, totalFrames: 1_920_000,
            accumulatedText: "hello", failedRanges: [.init(startFrame: 0, endFrame: 16_000)],
            updatedAt: Date(timeIntervalSince1970: 1_000),
            runConfiguration: configuration
        )
        store.save(progress, for: id)
        #expect(store.load(for: id) == progress)
    }

    @Test func legacySidecarWithoutRunConfigurationStillDecodes() throws {
        let data = Data("""
        {
          "lastFrame": 1,
          "totalFrames": 2,
          "accumulatedText": "hello",
          "failedRanges": [],
          "updatedAt": 0
        }
        """.utf8)

        let progress = try JSONDecoder().decode(SegmentedTranscriptionProgress.self, from: data)

        #expect(progress.runConfiguration == nil)
    }

    /// An import whose run never started (model still loading, engine not ready)
    /// has a working copy but no sidecar — the sidecar is only written once a
    /// batch completes. It must still count as resumable, otherwise the import
    /// is orphaned: the note stays blank forever and the copy leaks on disk.
    @Test func workingCopyWithoutSidecarIsStillPending() throws {
        let store = makeStore()
        let id = UUID()
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("import_\(UUID().uuidString).m4a")
        try Data("fake audio".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        _ = try store.importWorkingCopy(from: source, for: id)

        #expect(store.existingWorkingCopyURL(for: id) != nil)
        #expect(store.load(for: id) == nil)          // no sidecar yet
        #expect(store.listPendingNoteIDs().contains(id))
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

    @Test func beginTranscribingIsExclusivePerNote() {
        let store = makeStore()
        let id = UUID()
        #expect(store.beginTranscribing(id) == true)
        #expect(store.beginTranscribing(id) == false)   // already in progress
        store.endTranscribing(id)
        #expect(store.beginTranscribing(id) == true)     // freed, can start again
    }
}
