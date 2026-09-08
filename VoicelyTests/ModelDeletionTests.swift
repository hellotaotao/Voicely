#if DEBUG
import Foundation
import Testing
import WhisperKit
@testable import Voicely

@Suite(.serialized)
@MainActor
struct ModelDeletionTests {
    @Test func deletionRunsOffMainAndRemovesInventory() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ModelManager(downloadedModelsRoot: root, removeModelFiles: { url in
            #expect(!Thread.isMainThread)
            try FileManager.default.removeItem(at: url)
        })
        await manager.fetchModels(includeRemote: false)
        #expect(manager.downloadedModels.contains("small"))
        await manager.deleteModel("small")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("small").path))
        #expect(!manager.downloadedModels.contains("small"))
        #expect(manager.deletingModels.isEmpty)
    }

    @Test func failureRestoresLoadedModelAndRetryUnloadsIt() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let attempts = DeletionAttempts()
        let manager = ModelManager(loader: { _, _ in
            let kit = try await WhisperKit(WhisperKitConfig(prewarm: false, load: false, download: false))
            return ModelLoadResult(whisperKit: kit, sourceKind: .downloaded)
        }, downloadedModelsRoot: root, removeModelFiles: { url in
            if attempts.next() == 1 { throw DeletionFailure.failed }
            try FileManager.default.removeItem(at: url)
        })
        await manager.fetchModels(includeRemote: false)
        manager.selectedModel = "small"
        manager.availableModels = ["small", "other"]
        await manager.loadModel("small")
        await manager.deleteModel("small")
        #expect(manager.downloadedModels.contains("small"))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("small").path))
        #expect(manager.errorMessage != nil)
        #expect(manager.deletingModels.isEmpty)
        #expect(manager.isModelLoaded())
        #expect(manager.getWhisperKit() != nil)
        #expect(manager.currentModelIdentifier() == "small")
        #expect(manager.selectedModel == "small")
        await manager.deleteModel("small")
        #expect(!manager.isModelLoaded())
        #expect(manager.getWhisperKit() == nil)
        #expect(manager.modelState == .unloaded)
        #expect(!manager.downloadedModels.contains("small"))
        #expect(manager.selectedModel == "other")
        #expect(manager.errorMessage == nil)
    }

    @Test func deletingModelRejectsDuplicateAndSameModelLoadButAllowsOtherLoad() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = DeletionGate()
        defer { gate.release() }
        let manager = ModelManager(loader: { _, _ in
            let kit = try await WhisperKit(WhisperKitConfig(prewarm: false, load: false, download: false))
            return ModelLoadResult(whisperKit: kit, sourceKind: .downloaded)
        }, downloadedModelsRoot: root, removeModelFiles: { url in
            gate.wait()
            try FileManager.default.removeItem(at: url)
        })
        await manager.fetchModels(includeRemote: false)
        manager.selectedModel = "small"
        await manager.loadModel("small")
        let deletion = Task { await manager.deleteModel("small") }
        try await waitUntil { manager.deletingModels.contains("small") }
        #expect(!manager.isModelLoaded())
        #expect(manager.getWhisperKit() == nil)
        #expect(manager.currentModelIdentifier() == nil)
        await manager.deleteModel("small")
        await manager.loadModel("small", redownload: true)
        #expect(manager.errorMessage != nil)
        #expect(manager.loadedModelIdentifierInMemory == "small")
        await manager.loadModel("other")
        gate.release()
        await deletion.value
        #expect(manager.loadedModelIdentifierInMemory == "other")
        #expect(manager.modelState == .loaded)
        #expect(gate.callCount == 1)
    }

    @Test func supersededLoadStillProtectsItsFiles() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var pending: CheckedContinuation<ModelLoadResult, Error>?
        let manager = ModelManager(loader: { request, _ in
            if request.model == "small" {
                return try await withCheckedThrowingContinuation { pending = $0 }
            }
            let kit = try await WhisperKit(WhisperKitConfig(prewarm: false, load: false, download: false))
            return ModelLoadResult(whisperKit: kit, sourceKind: .downloaded)
        }, downloadedModelsRoot: root)
        await manager.fetchModels(includeRemote: false)
        let loading = Task { await manager.loadModel("small") }
        try await waitUntil { pending != nil }
        await manager.deleteModel("small")
        #expect(manager.downloadedModels.contains("small"))
        await manager.loadModel("other")
        await manager.deleteModel("small")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("small").path))
        pending?.resume(throwing: CancellationError())
        await loading.value
        await manager.deleteModel("small")
        #expect(!manager.downloadedModels.contains("small"))
        #expect(manager.loadedModelIdentifierInMemory == "other")
    }

    @Test func downloadedDeletionPreservesBundledFallback() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundledRoot = root.appendingPathComponent("resources")
        for component in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            try FileManager.default.createDirectory(
                at: bundledRoot.appendingPathComponent("BundledModels/small/\(component).mlmodelc"),
                withIntermediateDirectories: true
            )
        }
        let manager = ModelManager(downloadedModelsRoot: root, bundledModelsRoot: bundledRoot)
        await manager.fetchModels(includeRemote: false)
        manager.selectedModel = "small"
        await manager.deleteModel("small")
        #expect(manager.selectedModel == "small")
        #expect(manager.localModels.contains("small"))
        #expect(!manager.downloadedModels.contains("small"))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw DeletionFailure.failed }
            await Task.yield()
        }
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("small"), withIntermediateDirectories: true)
        return root
    }
}

private enum DeletionFailure: Error { case failed }

private final class DeletionAttempts: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}

private final class DeletionGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    private var calls = 0
    var callCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return calls
    }
    func wait() {
        condition.lock()
        calls += 1
        while !released { condition.wait() }
        condition.unlock()
    }
    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}
#endif
