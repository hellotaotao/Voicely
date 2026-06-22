import Foundation
import Testing
@testable import Voicely

@Suite @MainActor
struct ContentViewDropTests {
    @Test func keepsOnlySupportedAudioURLs() {
        let m4a = URL(fileURLWithPath: "/tmp/a.m4a")
        let mp3 = URL(fileURLWithPath: "/tmp/b.mp3")
        let wav = URL(fileURLWithPath: "/tmp/c.wav")
        let txt = URL(fileURLWithPath: "/tmp/d.txt")
        let png = URL(fileURLWithPath: "/tmp/e.png")

        let result = ContentView.supportedAudioURLs(from: [m4a, txt, mp3, png, wav])

        #expect(result == [m4a, mp3, wav])
    }

    @Test func emptyWhenNoSupportedAudio() {
        let result = ContentView.supportedAudioURLs(from: [
            URL(fileURLWithPath: "/tmp/x.txt"),
            URL(fileURLWithPath: "/tmp/y.pdf")
        ])
        #expect(result.isEmpty)
    }
}
