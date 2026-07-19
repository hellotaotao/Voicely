//
//  RecordingTempFileNamingTests.swift
//  VoicelyTests
//

import Foundation
import Testing
@testable import Voicely

struct RecordingTempFileNamingTests {

    /// Two recordings started within the same wall-clock second must not share a
    /// PCM path: the second `AVAudioFile(forWriting:)` would truncate the first
    /// one's file, and the first recording's deferred cleanup would then delete
    /// the audio the second one is still writing.
    @Test func consecutiveTempURLsAreUniqueWithinTheSameSecond() {
        let now = Date(timeIntervalSince1970: 1_783_345_803)
        let first = AudioRecordingService.makePCMTemporaryURL(now: now)
        let second = AudioRecordingService.makePCMTemporaryURL(now: now)

        #expect(first != second)
        #expect(first.pathExtension == "caf")
        #expect(second.pathExtension == "caf")
        #expect(first.lastPathComponent.hasPrefix("voicely_rec_"))
    }

    @Test func manyTempURLsStayUnique() {
        let now = Date(timeIntervalSince1970: 1_783_345_803)
        let urls = (0..<50).map { _ in AudioRecordingService.makePCMTemporaryURL(now: now) }
        #expect(Set(urls.map(\.lastPathComponent)).count == urls.count)
    }
}
