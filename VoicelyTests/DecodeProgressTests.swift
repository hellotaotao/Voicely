//
//  DecodeProgressTests.swift
//  VoicelyTests
//

import Foundation
import os
import Testing
@testable import Voicely

/// A 29 s slice is one engine call. A phone can take longer than iOS waits
/// for background progress, so progress has to come from inside the slice.
@MainActor
struct DecodeProgressTests {

    @Test func tokensInsideASlowSliceCountAsDecodeWork() async throws {
        let service = TranscriptionService()
        let (gate, release) = AsyncStream<Void>.makeStream()
        let (tokensEmitted, emitted) = AsyncStream<Void>.makeStream()
        service.transcribeSamples = { _, _, onToken in
            for _ in 0..<3 { onToken() }
            emitted.yield()
            for await _ in gate { break }
            onToken()
            return Qwen3SliceTranscript(text: "slow slice", tokenCount: 4, reachedTokenLimit: false)
        }
        var heartbeat = DecodeWorkHeartbeat(decodeWork: { service.decodeWorkCount })

        let decode = Task {
            try await service.decodePasses(
                Array(repeating: 0, count: 16_000), languageHint: nil, diagnosticID: "test", progress: { _ in })
        }
        for await _ in tokensEmitted { break }
        // The slice has not returned, yet the background task sees work.
        let advancedMidSlice = heartbeat.decoderAdvanced()
        #expect(advancedMidSlice)
        #expect(service.decodeWorkCount == 3)
        let advancedAgain = heartbeat.decoderAdvanced()
        #expect(!advancedAgain)

        release.yield()
        #expect(try await decode.value == ["slow slice"])
        #expect(service.decodeWorkCount == 4)
    }

    @Test func passesLongerThanTheEngineLimitAreCutAndReportProgress() async throws {
        let service = TranscriptionService()
        let limit = Int(Qwen3ASRDefaults.singlePassSecondsLimit * 16_000)
        let lengths = OSAllocatedUnfairLock(initialState: [Int]())
        service.transcribeSamples = { samples, _, onToken in
            lengths.withLock { $0.append(samples.count) }
            onToken()
            return Qwen3SliceTranscript(text: "\(samples.count)", tokenCount: 1, reachedTokenLimit: samples.count == limit)
        }
        var reported: [Float] = []

        let pieces = try await service.decodePasses(
            Array(repeating: 0, count: limit + 16_000), languageHint: nil, diagnosticID: "test",
            progress: { reported.append($0) })

        let passLengths = lengths.withLock { $0 }
        #expect(passLengths == [limit, 16_000])
        #expect(pieces == ["\(limit)", "16000"])
        #expect(reported.last == 1)
        #expect(service.decodeWorkCount == 2)
    }
}
