//
//  NoteFolder.swift
//  Voicely
//
//  Four fixed folder slots for the note library. A note stores only its slot
//  number (`VoiceNote.folderSlot`); the slot's name and color live here and
//  sync through CloudKit like the notes do.
//

import Foundation
import SwiftData
import SwiftUI

@Model
final class NoteFolder {
    /// 1...4. Slot 0 means "no folder" and never has a record.
    var slot: Int = 0
    var name: String = ""
    var colorIndex: Int = 0
    /// Two devices can create the same slot before syncing; the newest wins.
    var modifiedAt: Date = Date()

    init(slot: Int, name: String, colorIndex: Int) {
        self.slot = slot
        self.name = name
        self.colorIndex = colorIndex
        self.modifiedAt = Date()
    }
}

enum NoteFolderSlots {
    static let unfiled = 0
    static let all = 1...4

    static func isFolder(_ slot: Int) -> Bool { all.contains(slot) }
}

enum NoteFolderPalette {
    static let colors: [Color] = [.red, .orange, .yellow, .green, .teal, .blue, .purple, .pink]

    static func color(at index: Int) -> Color {
        colors[((index % colors.count) + colors.count) % colors.count]
    }

    /// Distinct starting colors so a new folder rarely needs a color change.
    static func defaultIndex(forSlot slot: Int) -> Int {
        switch slot {
        case 1: return 5 // blue
        case 2: return 3 // green
        case 3: return 1 // orange
        default: return 6 // purple
        }
    }
}

/// The folder records resolved to at most one per slot.
struct NoteFolderSet {
    private let bySlot: [Int: NoteFolder]

    init(_ records: [NoteFolder]) {
        var bySlot: [Int: NoteFolder] = [:]
        for record in records where NoteFolderSlots.isFolder(record.slot) {
            if let current = bySlot[record.slot], current.modifiedAt >= record.modifiedAt { continue }
            bySlot[record.slot] = record
        }
        self.bySlot = bySlot
    }

    func folder(forSlot slot: Int) -> NoteFolder? { bySlot[slot] }

    /// Configured folders in slot order.
    var folders: [NoteFolder] {
        NoteFolderSlots.all.compactMap { bySlot[$0] }
    }

    func color(forSlot slot: Int) -> Color? {
        bySlot[slot].map { NoteFolderPalette.color(at: $0.colorIndex) }
    }

    /// The lowest slot without a folder, where the next new folder goes.
    var firstEmptySlot: Int? {
        NoteFolderSlots.all.first { bySlot[$0] == nil }
    }

    /// What the folder bar shows. "No Folder" appears only once a folder exists,
    /// because before that it lists exactly what All lists. After the folders
    /// comes a single "+" for the next empty slot, until all four are taken.
    var barItems: [NoteFolderFilter] {
        var items: [NoteFolderFilter] = [.all]
        if !bySlot.isEmpty { items.append(.unfiled) }
        items += folders.map { .folder($0.slot) }
        if let slot = firstEmptySlot { items.append(.folder(slot)) }
        return items
    }
}

/// User-facing wording shared by the folder bar, the editor and menus.
enum NoteFolderCopy {
    static let noFolder = "No Folder"

    static func removalTitle(folderName: String) -> String {
        "Remove “\(folderName)”?"
    }

    static func removalMessage(noteCount: Int) -> String {
        noteCount == 1
            ? "Its recording stays, just outside any folder."
            : "Its \(noteCount) recordings stay, just outside any folder."
    }
}

/// Which part of the library the list shows.
enum NoteFolderFilter: Hashable {
    case all
    case unfiled
    case folder(Int)

    func includes(_ note: VoiceNote) -> Bool {
        switch self {
        case .all: return true
        case .unfiled: return !NoteFolderSlots.isFolder(note.folderSlot)
        case .folder(let slot): return note.folderSlot == slot
        }
    }

    /// The slot a recording or import started in this view goes into.
    var slotForNewNotes: Int {
        if case .folder(let slot) = self { return slot }
        return NoteFolderSlots.unfiled
    }
}

enum NoteLibraryFilter {
    static func notes(_ notes: [VoiceNote], in filter: NoteFolderFilter, matching searchText: String) -> [VoiceNote] {
        let query = NoteSearch.query(searchText)
        return notes.filter { note in
            guard filter.includes(note) else { return false }
            guard !query.isEmpty else { return true }
            return NoteSearch.contains(note.title, query) || NoteSearch.contains(note.transcription, query)
        }
    }
}

/// A note dragged onto a folder travels as a plain string, so no custom
/// type needs declaring; the prefix keeps arbitrary dropped text out.
enum NoteDragPayload {
    private static let prefix = "voicely-note:"

    static func string(for noteID: UUID) -> String { prefix + noteID.uuidString }

    static func noteID(from string: String) -> UUID? {
        guard string.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(string.dropFirst(prefix.count)))
    }
}
