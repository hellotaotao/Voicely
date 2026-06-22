import Foundation
import Testing
@testable import Voicely

@Suite @MainActor
struct ContentViewDropTests {
    @Test func acceptsCommonAudioExtensions() {
        for name in ["a.m4a", "b.m4b", "c.mp3", "d.wav", "e.wave", "f.aac", "g.aif", "h.aiff", "i.caf"] {
            #expect(
                CloudStorageManager.isSupportedImportedAudioURL(URL(fileURLWithPath: "/tmp/\(name)")),
                "expected \(name) to be accepted"
            )
        }
    }

    @Test func rejectsNonAudio() {
        for name in ["x.txt", "y.pdf", "z.png", "w.mov"] {
            #expect(
                !CloudStorageManager.isSupportedImportedAudioURL(URL(fileURLWithPath: "/tmp/\(name)")),
                "expected \(name) to be rejected"
            )
        }
    }
}
