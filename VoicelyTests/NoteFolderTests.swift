//
//  NoteFolderTests.swift
//  VoicelyTests
//

import Foundation
import Testing
@testable import Voicely

struct NoteFolderTests {

    private func note(_ title: String, slot: Int = 0, transcript: String = "") -> VoiceNote {
        let note = VoiceNote(title: title, transcription: transcript)
        note.folderSlot = slot
        return note
    }

    @Test func filterSplitsNotesByFolder() {
        let notes = [note("a"), note("b", slot: 2), note("c", slot: 3), note("stale", slot: 9)]
        func titles(_ filter: NoteFolderFilter) -> [String] {
            NoteLibraryFilter.notes(notes, in: filter, matching: "").map(\.title)
        }
        #expect(titles(.all) == ["a", "b", "c", "stale"])
        // A slot outside 1...4 counts as no folder, so the note is never lost.
        #expect(titles(.unfiled) == ["a", "stale"])
        #expect(titles(.folder(2)) == ["b"])
        #expect(titles(.folder(4)).isEmpty)
    }

    @Test func searchMatchesTitleOrTranscriptWithinTheFolder() {
        let notes = [
            note("Weekly sync", slot: 1, transcript: "budget review"),
            note("Dentist", transcript: "Café appointment"),
            note("Standup", slot: 1, transcript: "nothing new"),
        ]
        #expect(NoteLibraryFilter.notes(notes, in: .all, matching: "  BUDGET ").map(\.title) == ["Weekly sync"])
        #expect(NoteLibraryFilter.notes(notes, in: .all, matching: "cafe").map(\.title) == ["Dentist"])
        #expect(NoteLibraryFilter.notes(notes, in: .folder(1), matching: "stand").map(\.title) == ["Standup"])
        #expect(NoteLibraryFilter.notes(notes, in: .folder(1), matching: "cafe").isEmpty)
    }

    @Test func newNotesGoToTheShownFolder() {
        #expect(NoteFolderFilter.all.slotForNewNotes == 0)
        #expect(NoteFolderFilter.unfiled.slotForNewNotes == 0)
        #expect(NoteFolderFilter.folder(3).slotForNewNotes == 3)
    }

    @Test func newestRecordWinsWhenTwoDevicesCreatedTheSameSlot() {
        let older = NoteFolder(slot: 1, name: "Old", colorIndex: 0)
        older.modifiedAt = Date(timeIntervalSince1970: 100)
        let newer = NoteFolder(slot: 1, name: "New", colorIndex: 2)
        newer.modifiedAt = Date(timeIntervalSince1970: 200)
        let invalid = NoteFolder(slot: 0, name: "Bad", colorIndex: 0)
        let other = NoteFolder(slot: 4, name: "Four", colorIndex: 1)

        let set = NoteFolderSet([newer, invalid, other, older])
        #expect(set.folder(forSlot: 1)?.name == "New")
        #expect(set.folder(forSlot: 0) == nil)
        #expect(set.folders.map(\.name) == ["New", "Four"])
        #expect(set.color(forSlot: 2) == nil)
    }

    @Test func dragPayloadRoundTripsOnlyNoteIDs() {
        let id = UUID()
        #expect(NoteDragPayload.noteID(from: NoteDragPayload.string(for: id)) == id)
        #expect(NoteDragPayload.noteID(from: id.uuidString) == nil)
        #expect(NoteDragPayload.noteID(from: "voicely-note:not-a-uuid") == nil)
    }
}
