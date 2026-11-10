import AVFoundation
import Combine
import Testing
@testable import Voicely

/// The library and the open note observe `AudioRecordingService`, so the
/// duration tick must not reach them; only the clock views follow it.
@MainActor
struct RecordingClockTests {
    @Test func durationTicksDoNotRedrawWhatObservesTheService() {
        let service = AudioRecordingService()
        var serviceChanges = 0
        var clockChanges = 0
        let serviceSubscription = service.objectWillChange.sink { serviceChanges += 1 }
        let clockSubscription = service.clock.objectWillChange.sink { clockChanges += 1 }

        // Ten ticks a second for 2.5 s, as the recording timer sets it.
        for tick in 0...25 { service.recordingDuration = Double(tick) / 10 }

        #expect(serviceChanges == 0)
        #expect(clockChanges == 2)   // 0 → 1 → 2 s
        #expect(service.clock.seconds == 2)
        #expect(service.recordingDuration == 2.5)
        withExtendedLifetime((serviceSubscription, clockSubscription)) {}
    }

    @Test func clockIgnoresValuesItCannotShow() {
        let clock = RecordingClock()
        clock.show(.nan)
        clock.show(-3)
        #expect(clock.seconds == 0)
        clock.show(61.9)
        #expect(clock.seconds == 61)
    }

    @Test func aMacWithoutAMicrophoneHasNoUsableInput() throws {
        #expect(!AudioRecordingService.isUsableInput(AVAudioFormat()))
        let microphone = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        #expect(AudioRecordingService.isUsableInput(microphone))
    }
}
