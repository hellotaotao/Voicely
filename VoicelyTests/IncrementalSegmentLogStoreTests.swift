//
//  IncrementalSegmentLogStoreTests.swift
//  VoicelyTests
//
//  Created by Codex on 5/24/2026.
//

import Foundation
import Testing
@testable import Voicely

struct IncrementalSegmentLogStoreTests {
    @Test func appendsSegmentCutRecordsAsDurableJSONLines() throws {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("incremental_segments_\(UUID().uuidString).jsonl")
        let store = IncrementalSegmentLogStore(fileURL: logURL)
        let sessionID = UUID(uuidString: "7A013700-69F1-44E8-88D6-D0395AB50CC0")!

        try store.append(IncrementalSegmentLogRecord(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            sessionID: sessionID,
            recordingFileName: "recording.caf",
            segmentIndex: 1,
            cutKind: .voiceActivity,
            sampleRate: 16_000,
            startFrame: 0,
            requestedEndFrame: 464_000,
            endFrame: 361_600,
            targetIntervalSeconds: 29,
            usedVoiceActivityCut: true
        ))
        try store.append(IncrementalSegmentLogRecord(
            createdAt: Date(timeIntervalSince1970: 1_700_000_029),
            sessionID: sessionID,
            recordingFileName: "recording.caf",
            segmentIndex: 2,
            cutKind: .targetFallback,
            sampleRate: 16_000,
            startFrame: 361_600,
            requestedEndFrame: 825_600,
            endFrame: 825_600,
            targetIntervalSeconds: 29,
            usedVoiceActivityCut: true
        ))

        let records = try store.readRecords()

        #expect(records.count == 2)
        #expect(records[0].durationSeconds == 22.6)
        #expect(records[0].requestedDurationSeconds == 29.0)
        #expect(records[0].cutOffsetSeconds == 6.4)
        #expect(records[1].durationSeconds == 29.0)
        #expect(records[1].cutKind == .targetFallback)

        let rawLines = try String(contentsOf: logURL, encoding: .utf8).split(separator: "\n")
        #expect(rawLines.count == 2)

        try? FileManager.default.removeItem(at: logURL)
    }
}
