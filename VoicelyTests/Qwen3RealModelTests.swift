//
//  Qwen3RealModelTests.swift
//  VoicelyTests
//

import AVFoundation
import Foundation
import MLX
import Testing
@testable import Voicely

/// Input for the real-model check: place the weights and a recording at
/// `directory` (inside the test host's container) to enable it.
///   base/models/<org>/<name>/…   both repositories, Hub layout
///   audio.caf                    any recording AVAudioFile can read
///   expected.txt                 optional phrase the transcript must contain
enum Qwen3RealModelInput {
    static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("voicely-qwen-real", isDirectory: true)
    static let base = directory.appendingPathComponent("base", isDirectory: true)
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
        let base = Qwen3RealModelInput.base
        FileManager.default.createFile(
            atPath: Qwen3ASRModelStore.readyMarkerURL(for: backend, base: base).path, contents: nil)
        try #require(Qwen3ASRModelStore.isModelDownloaded(backend: backend, base: base),
                     "Weights for \(backend.rawValue) are missing under \(base.path)")

        let store = Qwen3ASRModelStore(backend: backend, baseDirectory: base)
        let loadStart = ProcessInfo.processInfo.systemUptime
        try await store.prepareDownloadedModel()
        let loadSeconds = ProcessInfo.processInfo.systemUptime - loadStart

        let samples = try Qwen3AudioPCM.loadPCM16kMono(url: Qwen3RealModelInput.audioURL)
        let slice = Int(Qwen3SliceLimits.production.chunkSeconds) * 16_000
        var pieces: [String] = []
        var audioSeconds = 0.0
        let decodeStart = ProcessInfo.processInfo.systemUptime
        var offset = 0
        while offset < min(samples.count, 60 * 16_000) {
            let end = min(offset + slice, samples.count)
            pieces.append(try await store.transcribe(samples: Array(samples[offset..<end]), languageHint: nil))
            audioSeconds += Double(end - offset) / 16_000
            offset = end
        }
        let decodeSeconds = ProcessInfo.processInfo.systemUptime - decodeStart
        let transcript = pieces.joined(separator: "\n")
        print("""
        QWEN-REAL backend=\(backend.rawValue) load=\(loadSeconds)s audio=\(audioSeconds)s \
        decode=\(decodeSeconds)s speed=\(audioSeconds / decodeSeconds)x
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
