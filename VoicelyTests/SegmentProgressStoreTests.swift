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
    @Test func retainedAttemptsSurviveResetAndSuccessfulCleanupWithoutBecomingPending() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let id = UUID()
        let progress = SegmentedTranscriptionProgress(lastFrame: 10, totalFrames: 20,
            accumulatedText: "Recovered fragment", failedRanges: [], updatedAt: Date())
        store.save(progress, for: id)
        try store.archiveProgressIfNeeded(for: id)
        try store.archiveProgressIfNeeded(for: id)
        #expect(store.listRetainedAttempts(for: id).count == 1)
        try store.resetProgressPreservingAttempt(for: id)
        #expect(store.load(for: id) == nil)
        #expect(store.existingWorkingCopyURL(for: id) == nil)
        #expect(store.listPendingNoteIDs().isEmpty)
        store.delete(for: id)
        store.removeWorkingCopy(for: id)
        #expect(store.listRetainedAttempts(for: id).first?.progress == progress)
        var next = progress
        next.updatedAt = progress.updatedAt.addingTimeInterval(1)
        next.accumulatedText = "Another fragment"
        store.save(next, for: id)
        try store.resetProgressPreservingAttempt(for: id)
        #expect(store.listRetainedAttempts(for: id).map(\.text) == ["Another fragment", "Recovered fragment"])
        store.deleteRetainedAttempts(for: id)
        #expect(store.listRetainedAttempts(for: id).isEmpty)
    }

    @Test func archiveWriteFailurePreventsCheckpointReset() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let id = UUID()
        let progress = SegmentedTranscriptionProgress(lastFrame: 10, totalFrames: 20,
            accumulatedText: "Keep this fragment", failedRanges: [], updatedAt: Date())
        store.save(progress, for: id)
        // A file where the archive directory belongs deterministically fails writes.
        try Data([1]).write(to: store.directory.appendingPathComponent("retained-attempts"))
        #expect(throws: (any Error).self) { try store.resetProgressPreservingAttempt(for: id) }
        #expect(store.load(for: id) == progress)
    }

    @Test func malformedCheckpointIsArchivedAsRawBytesBeforeReset() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let id = UUID()
        let source = store.directory.appendingPathComponent("\(id.uuidString).json")
        let original = Data("unreadable checkpoint".utf8)
        try original.write(to: source)
        try store.resetProgressPreservingAttempt(for: id)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        let folder = store.directory.appendingPathComponent("retained-attempts")
            .appendingPathComponent(id.uuidString)
        let archives = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        #expect(archives.count == 1)
        let archive = try #require(archives.first)
        #expect(archive.pathExtension == "raw")
        #expect(try Data(contentsOf: archive) == original)
        #expect(store.listRetainedAttempts(for: id).isEmpty)
        #expect(store.listPendingNoteIDs().isEmpty)
        #expect(store.existingWorkingCopyURL(for: id) == nil)
    }

    @Test func corruptCheckpointArchiveFailureStillPreventsReset() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let id = UUID()
        let source = store.directory.appendingPathComponent("\(id.uuidString).json")
        let original = Data("unreadable checkpoint".utf8)
        try original.write(to: source)
        try Data([1]).write(to: store.directory.appendingPathComponent("retained-attempts"))
        #expect(throws: (any Error).self) { try store.resetProgressPreservingAttempt(for: id) }
        #expect(try Data(contentsOf: source) == original)
    }

}
