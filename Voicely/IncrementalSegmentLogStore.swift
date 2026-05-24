//
//  IncrementalSegmentLogStore.swift
//  Voicely
//
//  Created by Codex on 5/24/2026.
//

import Foundation

enum IncrementalSegmentCutKind: String, Codable, Equatable, Sendable {
    case voiceActivity
    case targetFallback
    case final
}

struct IncrementalSegmentLogRecord: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let createdAt: Date
    let sessionID: UUID
    let recordingFileName: String
    let segmentIndex: Int
    let cutKind: IncrementalSegmentCutKind
    let sampleRate: Double
    let startFrame: Int64
    let requestedEndFrame: Int64
    let endFrame: Int64
    let durationSeconds: Double
    let requestedDurationSeconds: Double
    let cutOffsetSeconds: Double
    let targetIntervalSeconds: Int
    let usedVoiceActivityCut: Bool

    init(
        schemaVersion: Int = 1,
        createdAt: Date,
        sessionID: UUID,
        recordingFileName: String,
        segmentIndex: Int,
        cutKind: IncrementalSegmentCutKind,
        sampleRate: Double,
        startFrame: Int64,
        requestedEndFrame: Int64,
        endFrame: Int64,
        targetIntervalSeconds: Int,
        usedVoiceActivityCut: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.sessionID = sessionID
        self.recordingFileName = recordingFileName
        self.segmentIndex = segmentIndex
        self.cutKind = cutKind
        self.sampleRate = sampleRate
        self.startFrame = startFrame
        self.requestedEndFrame = requestedEndFrame
        self.endFrame = endFrame
        self.durationSeconds = Double(endFrame - startFrame) / sampleRate
        self.requestedDurationSeconds = Double(requestedEndFrame - startFrame) / sampleRate
        self.cutOffsetSeconds = max(0, Double(requestedEndFrame - endFrame) / sampleRate)
        self.targetIntervalSeconds = targetIntervalSeconds
        self.usedVoiceActivityCut = usedVoiceActivityCut
    }
}

protocol IncrementalSegmentLogWriting {
    var logFileURL: URL { get }

    func append(_ record: IncrementalSegmentLogRecord) throws
}

struct IncrementalSegmentLogStore: IncrementalSegmentLogWriting {
    static let fileName = "incremental_segment_cuts.jsonl"

    let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    var logFileURL: URL {
        fileURL
    }

    init(
        fileURL: URL = Self.defaultFileURL(),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func append(_ record: IncrementalSegmentLogRecord) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil)
        }

        var data = try encoder.encode(record)
        data.append(0x0A)

        let handle = try FileHandle(forWritingTo: fileURL)
        defer {
            handle.closeFile()
        }

        handle.seekToEndOfFile()
        handle.write(data)
        handle.synchronizeFile()
    }

    func readRecords() throws -> [IncrementalSegmentLogRecord] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }

        let content = try String(contentsOf: fileURL, encoding: .utf8)
        return try content.split(separator: "\n").map { line in
            try decoder.decode(
                IncrementalSegmentLogRecord.self,
                from: Data(line.utf8)
            )
        }
    }

    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let baseURL = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory

        return baseURL
            .appendingPathComponent("Voicely", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(fileName)
    }
}
