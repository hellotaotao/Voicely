//
//  VoiceNoteModelTests.swift
//  VoicelyTests
//
//  Created by Codex on 1/22/2026.
//

import Foundation
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
}
