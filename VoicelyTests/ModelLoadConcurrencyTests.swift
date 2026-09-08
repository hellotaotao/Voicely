import CoreML
import Testing
import WhisperKit
@testable import Voicely

@Suite(.serialized)
@MainActor
struct ModelLoadConcurrencyTests {
    @Test func identicalRequestsShareOneLoad() async throws {
        let loader = ControlledModelLoader()
        let manager = ModelManager(loader: loader.load)
        let first = Task { await manager.loadModel("small") }
        try await loader.waitForCalls(1)
        let second = Task { await manager.loadModel("small") }
        for _ in 0..<20 { await Task.yield() }
        #expect(loader.requests.count == 1)
        try await loader.succeed(0)
        await first.value
        await second.value
        #expect(manager.loadedModelIdentifierInMemory == "small")
        #expect(manager.modelState == .loaded)
    }

    @Test func supersededCompletionAndProgressCannotPublish() async throws {
        let loader = ControlledModelLoader()
        let manager = ModelManager(loader: loader.load)
        let first = Task { await manager.loadModel("small") }
        try await loader.waitForCalls(1)
        manager.encoderComputeUnits = .cpuOnly
        let second = Task { await manager.loadModel("small") }
        try await loader.waitForCalls(2)
        #expect(loader.requests[0].encoderComputeUnits == .cpuAndNeuralEngine)
        #expect(loader.requests[1].encoderComputeUnits == .cpuOnly)
        try await loader.succeed(1)
        await second.value
        loader.progress[0](.downloading, 0.2)
        try await loader.succeed(0)
        await first.value
        #expect(manager.modelState == .loaded)
        #expect(manager.loadingProgressValue == 1)
        #expect(manager.errorMessage == nil)
        await manager.loadModel("small")
        #expect(loader.requests.count == 2)
    }

    @Test func redownloadSupersedesNormalLoadAndIdenticalRedownloadJoins() async throws {
        let loader = ControlledModelLoader()
        let manager = ModelManager(loader: loader.load)
        let initial = Task { await manager.loadModel("small") }
        try await loader.waitForCalls(1)
        let replacement = Task { await manager.loadModel("small", redownload: true) }
        try await loader.waitForCalls(2)
        let joined = Task { await manager.loadModel("small", redownload: true) }
        for _ in 0..<20 { await Task.yield() }
        #expect(loader.requests.count == 2)
        try await loader.succeed(1)
        await replacement.value
        await joined.value
        loader.continuations[0].resume(throwing: CancellationError())
        await initial.value
        #expect(manager.modelState == .loaded)
    }

    @Test func failedRequestCanBeRetried() async throws {
        let loader = ControlledModelLoader()
        let manager = ModelManager(loader: loader.load)
        let initial = Task { await manager.loadModel("small") }
        try await loader.waitForCalls(1)
        loader.continuations[0].resume(throwing: TestFailure.failed)
        await initial.value
        #expect(manager.modelState == .unloaded)
        #expect(manager.errorMessage != nil)
        let retry = Task { await manager.loadModel("small") }
        try await loader.waitForCalls(2)
        #expect(manager.errorMessage == nil)
        try await loader.succeed(1)
        await retry.value
        #expect(manager.modelState == .loaded)
    }

    @Test func forcedReloadDoesNotReuseCompletedModel() async throws {
        let loader = ControlledModelLoader()
        let manager = ModelManager(loader: loader.load)
        let initial = Task { await manager.loadModel("small") }
        try await loader.waitForCalls(1)
        try await loader.succeed(0)
        await initial.value
        let reload = Task { await manager.loadModel("small", redownload: true) }
        try await loader.waitForCalls(2)
        #expect(loader.requests[1].redownload)
        try await loader.succeed(1)
        await reload.value
        #expect(manager.modelState == .loaded)
    }

    @Test func cancellingOneWaiterDoesNotCancelSharedLoad() async throws {
        let loader = ControlledModelLoader()
        let manager = ModelManager(loader: loader.load)
        let first = Task { await manager.loadModel("small") }
        try await loader.waitForCalls(1)
        let second = Task { await manager.loadModel("small") }
        for _ in 0..<20 { await Task.yield() }
        first.cancel()
        try await loader.succeed(0)
        await first.value
        await second.value
        #expect(loader.requests.count == 1)
        #expect(manager.modelState == .loaded)
    }

    @Test func staleFailureCannotClearNewModel() async throws {
        let loader = ControlledModelLoader()
        let manager = ModelManager(loader: loader.load)
        let first = Task { await manager.loadModel("old") }
        try await loader.waitForCalls(1)
        let second = Task { await manager.loadModel("new", redownload: true) }
        try await loader.waitForCalls(2)
        #expect(loader.requests[1].redownload)
        try await loader.succeed(1)
        await second.value
        loader.continuations[0].resume(throwing: TestFailure.failed)
        await first.value
        #expect(manager.loadedModelIdentifierInMemory == "new")
        #expect(manager.modelState == .loaded)
        #expect(manager.errorMessage == nil)
    }
}

private enum TestFailure: Error { case failed }

@MainActor
private final class ControlledModelLoader {
    var requests: [ModelLoadRequest] = []
    var progress: [ModelManager.LoadProgress] = []
    var continuations: [CheckedContinuation<ModelLoadResult, Error>] = []

    func load(_ request: ModelLoadRequest, _ progress: @escaping ModelManager.LoadProgress) async throws -> ModelLoadResult {
        requests.append(request)
        self.progress.append(progress)
        return try await withCheckedThrowingContinuation { continuations.append($0) }
    }

    func waitForCalls(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while requests.count < count {
            guard ContinuousClock.now < deadline else { throw TestFailure.failed }
            await Task.yield()
        }
    }

    func succeed(_ index: Int) async throws {
        let kit = try await WhisperKit(WhisperKitConfig(prewarm: false, load: false, download: false))
        continuations[index].resume(returning: ModelLoadResult(whisperKit: kit, sourceKind: .downloaded))
    }
}
