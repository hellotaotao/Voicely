//
//  SliceEndReasonReplayTests.swift
//  VoicelyTests
//

import Foundation
import os
import Testing
@testable import Voicely

/// Decodes every production slice of the recordings `VADCutReplayTests` cut
/// (`cuts-<name>.caf` with its `cuts-<name>.json`) and records how each slice
/// ended. A slice that hits the token cap loses its tail without any error, and
/// the longest wait between tokens is what background progress depends on.
/// Writes `endreason-<name>-<backend>.json`. Opt-in because it decodes hours of
/// audio: run with `TEST_RUNNER_VOICELY_RUN_END_REASON_REPLAY=1`, and
/// `TEST_RUNNER_VOICELY_BACKEND=mlx|coreML` to pick the backend.
@Suite(.serialized, .enabled(if:
    ProcessInfo.processInfo.environment["VOICELY_RUN_END_REASON_REPLAY"] == "1" && VADCutReplayInput.isConfigured))
struct SliceEndReasonReplayTests {
    private struct Cut: Decodable {
        let start: Double
        let end: Double
    }

    private struct Pass: Encodable {
        let start: Double
        let end: Double
        let tokens: Int
        let reachedTokenLimit: Bool
        let seconds: Double
        let longestTokenGap: Double
        let text: String
    }

    @Test func recordHowEverySliceEnds() async throws {
        let backend = Qwen3Backend.current
        let bundled = Qwen3ASRModelStore.defaultModelDirectory()
        let directory = bundled.flatMap { Qwen3ASRModelStore.isComplete($0, backend: backend) ? $0 : nil }
            ?? Qwen3RealModelInput.directory.appendingPathComponent(backend.rawValue, isDirectory: true)
        try #require(Qwen3ASRModelStore.isComplete(directory, backend: backend))
        let store = Qwen3ASRModelStore(backend: backend, modelDirectory: directory)
        try await store.prepareModel()

        for url in VADCutReplayInput.audioURLs {
            let name = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "cuts-", with: "")
            let cutsURL = url.deletingPathExtension().appendingPathExtension("json")
            let cuts = try JSONDecoder().decode([Cut].self, from: Data(contentsOf: cutsURL))
            let samples = try Qwen3AudioPCM.loadPCM16kMono(url: url)

            var passes: [Pass] = []
            for cut in cuts {
                let range = Int(cut.start * 16_000)..<min(Int(cut.end * 16_000), samples.count)
                guard !range.isEmpty else { continue }
                let started = ProcessInfo.processInfo.systemUptime
                let ticks = OSAllocatedUnfairLock(initialState: (last: started, longest: 0.0))
                let pass = try await store.transcribe(samples: Array(samples[range]), languageHint: nil) {
                    ticks.withLock {
                        let now = ProcessInfo.processInfo.systemUptime
                        $0 = (now, max($0.longest, now - $0.last))
                    }
                }
                passes.append(Pass(
                    start: cut.start, end: cut.end, tokens: pass.tokenCount,
                    reachedTokenLimit: pass.reachedTokenLimit,
                    seconds: ProcessInfo.processInfo.systemUptime - started,
                    longestTokenGap: ticks.withLock { $0.longest }, text: pass.text))
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try encoder.encode(passes).write(to: VADCutReplayInput.directory
                .appendingPathComponent("endreason-\(name)-\(backend.rawValue).json"))
            let capped = passes.filter(\.reachedTokenLimit)
            let audio = passes.reduce(0) { $0 + $1.end - $1.start }
            let decode = passes.reduce(0) { $0 + $1.seconds }
            print("""
            END-REASON \(name) backend=\(backend.rawValue) slices=\(passes.count) capped=\(capped.count) \
            maxTokens=\(passes.map(\.tokens).max() ?? 0) \
            longestTokenGap=\(passes.map(\.longestTokenGap).max() ?? 0)s \
            longestSlice=\(passes.map(\.seconds).max() ?? 0)s speed=\(audio / decode)x
            """)
            for pass in capped {
                print("END-REASON capped \(name) \(pass.start)–\(pass.end) s: …\(pass.text.suffix(80))")
            }
        }
        await store.unloadModel()
    }
}
