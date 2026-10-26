# Privacy And App Review Notes

Release-prep draft, not legal advice. Confirm the final App Privacy answers in App Store Connect against the exact archived build.

## Implementation References

- Microphone capture: `Voicely/AudioRecordingService.swift`. Live PCM goes to `Application Support/LiveRecordings` (excluded from backups) and is exported to `.m4a` when recording stops.
- On-device speech recognition: `Voicely/Qwen3TranscriptionEngine.swift` (Qwen3-ASR 0.6B, bundled as `SpeechModel/` in the app). Mac: MLX on the GPU. iPhone and iPad: Core ML on the CPU and Neural Engine.
- Voice activity detection: bundled Silero VAD Core ML model (`Voicely/silero_vad.mlmodelc`, `Voicely/NeuralSpeechAnalyzer.swift`).
- Note model: `VoiceNote` in `Voicely/Item.swift`.
- iCloud: SwiftData with CloudKit (`Voicely/VoicelyApp.swift`), audio in iCloud Documents (`Voicely/CloudStorageManager.swift`).
- Local notifications for scheduled stops: `Voicely/RecordingStopNotifier.swift`.
- Background work: `UIBackgroundModes` (`audio`, `processing`, `remote-notification`) and `BGTaskSchedulerPermittedIdentifiers` in `Voicely/Info.plist`; continued processing on iOS 26 in `Voicely/ContinuedProcessingTask.swift`.
- Entitlements: `Voicely/Voicely.entitlements`. Export compliance flag: `ITSAppUsesNonExemptEncryption = false` in `Voicely/Info.plist`.

## Network Use

The app makes no network requests of its own. The speech and VAD models are inside the app bundle; there is no model download, account, analytics, advertising, or crash-reporting SDK. The only traffic is Apple's:

- CloudKit sync of notes and iCloud Drive sync of audio, when iCloud is available for the app.
- Push notifications CloudKit uses to announce changes (`remote-notification`).

Without iCloud, audio stays in the app's local Documents folder and notes in the local store; everything else works the same.

## App Review Notes

Paste into App Store Connect, adjusted for the final build:

> Voicely records meetings and transcribes them on the device. The speech recognition model (Qwen3-ASR) is bundled with the app, which is why the download is about 1.1 GB. The app never downloads models and never uploads audio or text for transcription; the developer runs no server. No account or login is needed.
>
> To test: allow microphone access when the app first opens, tap the record button, speak for 20–30 seconds, then stop. Text appears while recording and the note completes a few seconds after stopping. Tap a sentence to play from there. Settings shows the speech model and an optional language setting (Auto Detect by default).
>
> The audio background mode keeps recording and live transcription running when the screen locks, as in any voice recorder; a Live Activity shows the recording on the Lock Screen and Dynamic Island. Background processing is used to finish transcribing after a recording stops.
>
> iCloud sync is optional and uses the user's own iCloud account (CloudKit private database and iCloud Drive). The developer has no server and no access to user data.
>
> The Mac version requires Apple silicon.

## App Privacy Nutrition Label

### Recommendation: Data Not Collected

Apple defines collecting as transmitting data off the device in a way that lets the developer or a third party access it. Voicely sends nothing to the developer or any third party:

- Transcription and VAD run on the device.
- iCloud sync stores notes in the user's CloudKit **private** database and audio in the user's iCloud Drive container. Both belong to the user's Apple account; the developer cannot read them.
- No analytics, advertising, crash-reporting, or other third-party SDKs.
- The per-device identifier written into notes (`transcriptionOriginDeviceID`, a random UUID used to decide which device transcribes a note) is not an advertising identifier and only travels inside the user's own iCloud data.

Tracking: No. Data linked to the user: none. Data used for advertising: none.

If the owner prefers the conservative reading of iCloud sync, declare instead: User Content > Audio Data and Other User Content, purpose App Functionality, linked to the user, not used for tracking. Pick one answer and make the privacy policy match it.

## Privacy Policy Draft

> **Voicely Privacy Policy**
>
> Voicely does not collect any personal data. There is no account, no analytics, no advertising, and no developer server.
>
> **Recordings and transcripts.** Audio you record or import and the transcripts Voicely creates are stored on your device. Speech recognition runs entirely on your device; audio is never sent anywhere to be transcribed.
>
> **iCloud.** If iCloud is turned on for Voicely, your notes and audio sync between your devices through your own iCloud account, under Apple's privacy policy. The developer cannot access your iCloud data. Turn off iCloud for Voicely in Settings to keep everything on one device.
>
> **Permissions.** Microphone access is used only while you record. Notification permission is used only for reminders and confirmations when you set a recording to stop at a certain time.
>
> **Deleting data.** Deleting a note deletes its audio and transcript; with iCloud on, the deletion syncs to your other devices. Deleting the app removes its local data.
>
> **Contact.** TODO: support email or page.

## Permissions

| Permission | When it is asked | Purpose string |
| --- | --- | --- |
| Microphone | First launch (`AudioRecordingService.init` calls `checkPermission()`) | `NSMicrophoneUsageDescription`: "This app needs access to your microphone to record voice notes for transcription." |
| Notifications | First time a stop time is set | System prompt; no purpose string. Used for the reminder before a scheduled stop and the "saved" confirmation. |

Consider rewording the microphone string to name the feature reviewers look for, e.g. "Voicely uses the microphone to record meetings so it can transcribe them on this device."

## Export Compliance

`ITSAppUsesNonExemptEncryption` is `false`. The app implements no encryption of its own and only uses Apple's platform services (CloudKit, iCloud Drive). Answer that the app does not use non-exempt encryption, as long as nothing changes before the archive.

## Review Risks To Check Before Submission

- **CloudKit production schema.** Deploy the development schema to production in CloudKit Console before the release build ships; the production schema has lagged behind before, which breaks sync for Release and TestFlight builds.
- **Push environment.** The checked-in entitlements use the development APNs environment; confirm the archived build's entitlements show production in Organizer.
- **Background claims.** The listing says transcription continues after locking the iPhone. Confirm it on a real iPhone (roadmap item 6) before submitting, on both iOS 18 and iOS 26, since finishing after stop uses continued processing only on iOS 26.
- **Download size.** About 1.1 GB per platform. Reviewers and users on cellular will see the large-download prompt; the review note explains it.
- **Mac.** The Mac build is arm64 only; set Apple silicon as the requirement and make sure no Intel Mac is offered the app.
