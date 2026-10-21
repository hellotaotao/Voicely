//
//  OrphanedRecordingRecovery.swift
//  Voicely
//

import AVFoundation
import Foundation

/// File-system access for recovering recordings whose process died before stop
/// (crash, app update, jetsam). Such a note never got its `.m4a`; the only audio
/// left is the live PCM file in tmp. Tests replace these hooks.
struct OrphanedRecordingStorage {
    /// Directory the recorder writes live PCM files into.
    var temporaryDirectory: () -> URL
    /// True when neither the audio nor its iCloud placeholder is on this device.
    var isAudioAbsent: @MainActor (String) -> Bool
    /// Where a recovered recording is exported, given the note's audio file name.
    var destinationURL: @MainActor (String) -> URL
    var duration: (URL) -> TimeInterval?
    var convert: @Sendable (URL, URL) async throws -> Void

    @MainActor static var live: OrphanedRecordingStorage {
        OrphanedRecordingStorage(
            temporaryDirectory: { FileManager.default.temporaryDirectory },
            isAudioAbsent: { path in
                let cloud = CloudStorageManager.shared
                guard let url = cloud.getFileURL(for: path) else { return true }
                return cloud.isAudioFileMissing(at: url)
            },
            destinationURL: { name in
                CloudStorageManager.shared.getAudioStorageDirectory().appendingPathComponent(name)
            },
            duration: { url in
                guard let file = try? AVAudioFile(forReading: url) else { return nil }
                return Double(file.length) / file.fileFormat.sampleRate
            },
            convert: { source, destination in
                try await AudioRecordingService.convertCAFToM4A(from: source, to: destination)
            }
        )
    }
}

/// Pairs notes with the live PCM files left behind by their recordings.
enum OrphanedRecordingMatcher {
    /// The `.m4a` name, the PCM name and the note's timestamp are all taken while
    /// starting one recording, well under this apart; separate recordings are not.
    static let maximumStartGap: TimeInterval = 5

    /// The whole second the recording started, from `voicely_rec_<unixSeconds>_<uuid>.caf`.
    static func startTime(ofPCMFile url: URL) -> TimeInterval? {
        let name = url.lastPathComponent
        let prefix = AudioRecordingService.pcmTemporaryFilePrefix
        guard name.hasPrefix(prefix), url.pathExtension == "caf" else { return nil }
        let seconds = name.dropFirst(prefix.count).prefix { $0 != "_" }
        return TimeInterval(seconds)
    }

    /// When the note's recording started: from its `recording_<unixTime>.m4a`
    /// name, else the note's creation time.
    static func startTime(of note: VoiceNote) -> TimeInterval {
        let name = URL(fileURLWithPath: note.audioFilePath).deletingPathExtension().lastPathComponent
        let prefix = "recording_"
        if name.hasPrefix(prefix), let seconds = TimeInterval(name.dropFirst(prefix.count)) {
            return seconds
        }
        return note.timestamp.timeIntervalSince1970
    }

    /// Gives each note the closest unclaimed PCM file within `maximumStartGap`.
    static func match(_ notes: [VoiceNote], to pcmFiles: [URL]) -> [UUID: URL] {
        var available = pcmFiles.compactMap { url in startTime(ofPCMFile: url).map { (url, $0) } }
        var matches: [UUID: URL] = [:]
        for note in notes {
            let noteStart = startTime(of: note)
            // PCM names truncate to whole seconds, so compare against the second it fell in.
            let gaps = available.map { abs(floor(noteStart) - $0.1) }
            guard let index = gaps.indices.min(by: { gaps[$0] < gaps[$1] }),
                  gaps[index] <= maximumStartGap else { continue }
            matches[note.id] = available.remove(at: index).0
        }
        return matches
    }
}
