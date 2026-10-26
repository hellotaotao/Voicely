//
//  Qwen3RealModelTests.swift
//  VoicelyTests
//

import AVFoundation
import Foundation
import MLX
import os
import Testing
@testable import Voicely

/// Input for the real-model check: place a recording at `directory` (inside
/// the test host's container) to enable it. The backend the app bundles is
/// read from the app; the other one needs its folder here.
///   audio.caf      any recording AVAudioFile can read
///   expected.txt   optional phrase the transcript must contain
///   mlx/, coreML/  the other backend's model folder, as in Models/ from
///                  scripts/fetch-speech-models.sh
enum Qwen3RealModelInput {
    static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("voicely-qwen-real", isDirectory: true)
    static let audioURL = directory.appendingPathComponent("audio.caf")
    static var isConfigured: Bool { FileManager.default.fileExists(atPath: audioURL.path) }
}

/// Loads the real Qwen3-ASR weights on each backend and transcribes the first
/// minute of a recording, slice by slice, the way the app does. Unit tests
/// stub the decoder, so this is the only test where the model itself runs.
@Suite(.serialized, .enabled(if: Qwen3RealModelInput.isConfigured))
struct Qwen3RealModelTests {
    @Test(arguments: [Qwen3Backend.mlx, .coreML])
    func transcribesARealRecording(backend: Qwen3Backend) async throws {
        let bundled = Qwen3ASRModelStore.defaultModelDirectory()
        let directory = bundled.flatMap { Qwen3ASRModelStore.isComplete($0, backend: backend) ? $0 : nil }
            ?? Qwen3RealModelInput.directory.appendingPathComponent(backend.rawValue, isDirectory: true)
        try #require(Qwen3ASRModelStore.isComplete(directory, backend: backend),
                     "The \(backend.rawValue) model is missing from \(directory.path)")

        let store = Qwen3ASRModelStore(backend: backend, modelDirectory: directory)
        let loadStart = ProcessInfo.processInfo.systemUptime
        try await store.prepareModel()
        let loadSeconds = ProcessInfo.processInfo.systemUptime - loadStart

        let samples = try Qwen3AudioPCM.loadPCM16kMono(url: Qwen3RealModelInput.audioURL)
        let slice = Int(Qwen3SliceLimits.production.chunkSeconds) * 16_000
        var pieces: [String] = []
        var audioSeconds = 0.0
        let decodeStart = ProcessInfo.processInfo.systemUptime
        // Background tasks see progress only through the token callback, so the
        // longest wait between tokens is what a slow phone has to stay under.
        let ticks = OSAllocatedUnfairLock(initialState: (count: 0, last: decodeStart, longestGap: 0.0))
        var offset = 0
        while offset < min(samples.count, 60 * 16_000) {
            let end = min(offset + slice, samples.count)
            let before = ticks.withLock { $0.count }
            ticks.withLock { $0.last = ProcessInfo.processInfo.systemUptime }
            let pass = try await store.transcribe(samples: Array(samples[offset..<end]), languageHint: nil) {
                ticks.withLock {
                    let now = ProcessInfo.processInfo.systemUptime
                    $0 = ($0.count + 1, now, max($0.longestGap, now - $0.last))
                }
            }
            let reported = ticks.withLock { $0.count } - before
            #expect(pass.tokenCount > 0)
            #expect(reported == pass.tokenCount)
            #expect(!pass.reachedTokenLimit)
            pieces.append(pass.text)
            audioSeconds += Double(end - offset) / 16_000
            offset = end
        }
        let decodeSeconds = ProcessInfo.processInfo.systemUptime - decodeStart
        let transcript = pieces.joined(separator: "\n")
        print("""
        QWEN-REAL backend=\(backend.rawValue) load=\(loadSeconds)s audio=\(audioSeconds)s \
        decode=\(decodeSeconds)s speed=\(audioSeconds / decodeSeconds)x \
        tokens=\(ticks.withLock { $0.count }) longestTokenGap=\(ticks.withLock { $0.longestGap })s
        \(transcript)
        QWEN-REAL end
        """)

        #expect(pieces.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        if let expected = try? String(
            contentsOf: Qwen3RealModelInput.directory.appendingPathComponent("expected.txt"), encoding: .utf8) {
            let phrase = expected.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(transcript.localizedCaseInsensitiveContains(phrase))
        }
        // Unbounded, MLX's buffer cache grew past 12 GB in one long recording.
        let footprint = Self.physicalFootprint()
        print("QWEN-REAL backend=\(backend.rawValue) footprintMB=\(footprint / 1_048_576)")
        #expect(footprint < 4 * 1_073_741_824)
        if backend == .mlx {
            #expect(Memory.cacheLimit == Qwen3ASRDefaults.mlxCacheLimitBytes)
            print("QWEN-REAL cacheMB=\(Memory.cacheMemory / 1_048_576) activeMB=\(Memory.activeMemory / 1_048_576)")
        }
        await store.unloadModel()
    }

    /// A CoreML slice runs as one synchronous call; cancelling it must stop
    /// between tokens instead of after the whole slice.
    @Test func cancellingStopsACoreMLSliceBetweenTokens() async throws {
        let bundled = Qwen3ASRModelStore.defaultModelDirectory()
        let directory = bundled.flatMap { Qwen3ASRModelStore.isComplete($0, backend: .coreML) ? $0 : nil }
            ?? Qwen3RealModelInput.directory.appendingPathComponent(Qwen3Backend.coreML.rawValue, isDirectory: true)
        try #require(Qwen3ASRModelStore.isComplete(directory, backend: .coreML))
        let store = Qwen3ASRModelStore(backend: .coreML, modelDirectory: directory)
        try await store.prepareModel()
        let samples = try Qwen3AudioPCM.loadPCM16kMono(url: Qwen3RealModelInput.audioURL)
        let slice = Array(samples.prefix(Int(Qwen3SliceLimits.production.chunkSeconds) * 16_000))

        let tokens = OSAllocatedUnfairLock(initialState: 0)
        let (firstToken, signal) = AsyncStream<Void>.makeStream()
        let decode = Task {
            try await store.transcribe(samples: slice, languageHint: nil) {
                let count = tokens.withLock { $0 += 1; return $0 }
                if count == 1 {
                    signal.yield()
                    // Give the test time to cancel before the next token.
                    Thread.sleep(forTimeInterval: 0.2)
                }
            }
        }
        for await _ in firstToken { break }
        decode.cancel()
        await #expect(throws: CancellationError.self) { try await decode.value }
        let emittedTokens = tokens.withLock { $0 }
        #expect(emittedTokens <= 2)
        await store.unloadModel()
    }

    /// The process's real memory use, GPU buffers included.
    static func physicalFootprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}
