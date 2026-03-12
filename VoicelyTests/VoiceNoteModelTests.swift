//
//  VoiceNoteModelTests.swift
//  VoicelyTests
//
//  Created by Codex on 1/22/2026.
//

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
}
