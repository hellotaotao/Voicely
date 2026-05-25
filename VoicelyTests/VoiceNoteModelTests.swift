//
//  VoiceNoteModelTests.swift
//  VoicelyTests
//
//  Created by Codex on 1/22/2026.
//

import Foundation
import AVFoundation
import SwiftData
import Testing
@testable import Voicely

struct VoiceNoteModelTests {

    @Test func voiceNotePersistsInMemoryContainer() throws {
        let schema = Schema([VoiceNote.self])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)

        let note = VoiceNote(title: "Test Note", audioFilePath: "file.m4a")
        context.insert(note)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<VoiceNote>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.title == "Test Note")
        #expect(fetched.first?.audioFilePath == "file.m4a")
    }

    @Test func waveformSeedIsStableForKnownUUID() throws {
        let uuid = try #require(UUID(uuidString: "12345678-1234-5678-9ABC-DEF012345678"))

        let first = WaveformSeedGenerator.stableSeed(for: uuid)
        let second = WaveformSeedGenerator.stableSeed(for: uuid)

        #expect(first == second)
        #expect(first == 8759)
    }

    @Test func waveformNormalizationKeepsSilenceVisible() {
        let levels = AudioWaveformExtractor.normalizedLevels(from: [0, 0, 0])

        #expect(levels == [0.08, 0.08, 0.08])
    }

    @Test func waveformExtractionReflectsAudioAmplitudeBuckets() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicely-waveform-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }

        let sampleRate = 8_000.0
        let segmentFrameCount = Int(sampleRate)
        let amplitudes: [Float] = [0.05, 0.75, 0.2]
        let totalFrameCount = segmentFrameCount * amplitudes.count
        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
        )
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrameCount))
        )
        buffer.frameLength = AVAudioFrameCount(totalFrameCount)

        let channel = try #require(buffer.floatChannelData?[0])
        for frameIndex in 0..<totalFrameCount {
            let segmentIndex = min(frameIndex / segmentFrameCount, amplitudes.count - 1)
            channel[frameIndex] = amplitudes[segmentIndex]
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)

        let levels = try await AudioWaveformExtractor.normalizedLevels(from: url, bucketCount: 3)

        #expect(levels.count == 3)
        #expect(levels[1] > levels[2])
        #expect(levels[2] > levels[0])
    }
}
