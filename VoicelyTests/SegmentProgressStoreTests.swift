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
