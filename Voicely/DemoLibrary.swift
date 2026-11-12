//
//  DemoLibrary.swift
//  Voicely
//
//  Debug-only sample library for screenshots. scripts/demo-library builds
//  library.json and the audio it points to; launching the Debug app with
//  VOICELY_DEMO_DIR set inserts those invented notes into the in-memory store.
//

#if DEBUG
import Foundation
import SwiftData

enum DemoLibrary {
    /// Elapsed time of the demo note shown mid-recording, if the library has one.
    @MainActor static private(set) var recordingElapsedSeconds: TimeInterval?

    private struct Library: Decodable {
        var folders: [Folder]
        var notes: [Note]
    }

    private struct Folder: Decodable {
        var slot: Int
        var name: String
        var colorIndex: Int
    }

    private struct Note: Decodable {
        var title: String
        var hoursAgo: Double
        var folderSlot: Int
        var engine: String
        var audioFile: String?
        var durationSeconds: Double?
        /// Shows the note mid-recording, this many seconds in, with its text as the live transcript.
        var recordingSeconds: Double?
        var sentences: [Sentence]
    }

    private struct Sentence: Decodable {
        var text: String
        var start: TimeInterval?
        var end: TimeInterval?
    }

    @MainActor
    static func seed(into context: ModelContext) {
        guard let path = ProcessInfo.processInfo.environment["VOICELY_DEMO_DIR"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let library: Library
        do {
            let data = try Data(contentsOf: directory.appendingPathComponent("library.json"))
            library = try JSONDecoder().decode(Library.self, from: data)
        } catch {
            debugLog("❌ [Demo] Could not read library.json in \(path): \(error)")
            return
        }

        for folder in library.folders {
            context.insert(NoteFolder(slot: folder.slot, name: folder.name, colorIndex: folder.colorIndex))
        }

        // The note shown mid-recording only joins the library for recording screenshots.
        let showsRecording = ProcessInfo.processInfo.environment["VOICELY_DEMO_RECORDING"] == "1"
        for item in library.notes where item.recordingSeconds == nil || showsRecording {
            let audioPath = item.audioFile.map { directory.appendingPathComponent($0).path } ?? ""
            let note = VoiceNote(title: item.title, audioFilePath: audioPath)
            note.titleWasManuallyEdited = true
            note.timestamp = Date().addingTimeInterval(-item.hoursAgo * 3600)
            note.folderSlot = item.folderSlot

            var builder = TranscriptSpanBuilder()
            var text = ""
            for sentence in item.sentences {
                if !text.isEmpty { text += " " }
                text += sentence.text
                if let start = sentence.start, let end = sentence.end {
                    builder.append(sentence.text, start: start, end: end)
                }
            }
            let spans = item.sentences.allSatisfy { $0.start != nil } ? builder.spans : nil
            note.transcriptionModelIdentifier = modelIdentifier(for: item.engine)
            if let elapsed = item.recordingSeconds {
                // Still recording: no duration yet, and the transcript is the live one.
                note.duration = 0
                note.setTranscript(text, spans: nil)
                note.isTranscribing = true
                recordingElapsedSeconds = elapsed
            } else {
                note.duration = item.durationSeconds ?? item.sentences.last?.end ?? 0
                note.setTranscript(text, spans: spans)
                note.completeTranscription()
            }
            context.insert(note)
        }

        do {
            try context.save()
            debugLog("✅ [Demo] Seeded \(library.notes.count) sample notes")
        } catch {
            debugLog("❌ [Demo] Could not save sample notes: \(error)")
        }
    }

    private static func modelIdentifier(for engine: String) -> String {
        switch engine {
        case "parakeet": EnglishStretchRouting.parakeetOnlyModelIdentifier
        case "mixed": EnglishStretchRouting.modelIdentifier(afterParakeet: nil)
        default: Qwen3Backend.current.modelIdentifier
        }
    }
}
#endif
