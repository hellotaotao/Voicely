# Privacy And App Review Notes

These notes are a release-prep draft, not legal advice. Confirm final App Privacy answers in App Store Connect against the exact archived build.

## Implementation References

- Microphone capture: `Voicely/AudioRecordingService.swift:67`, `Voicely/AudioRecordingService.swift:116`
- Local WhisperKit transcription: `Voicely/TranscriptionService.swift:631`, `Voicely/TranscriptionService.swift:723`
- Model download and local model storage: `Voicely/ModelManager.swift:103`, `Voicely/ModelManager.swift:127`, `Voicely/ModelManager.swift:258`, `Voicely/ModelManager.swift:325`
- Voice note data model: `Voicely/Item.swift:17`
- SwiftData CloudKit configuration: `Voicely/VoicelyApp.swift:18`, `Voicely/VoicelyApp.swift:22`
- iCloud audio file storage and sync: `Voicely/CloudStorageManager.swift:23`, `Voicely/CloudStorageManager.swift:25`, `Voicely/CloudStorageManager.swift:89`
- Entitlements: `Voicely/Voicely.entitlements:5`, `Voicely/Voicely.entitlements:9`, `Voicely/Voicely.entitlements:13`
- Export compliance flag: `Voicely/Info.plist:10`
- Permission strings in build settings: `Voicely.xcodeproj/project.pbxproj:312`, `Voicely.xcodeproj/project.pbxproj:357`

## App Review Notes Draft

Voicely is a user-initiated meeting recorder and transcription app.

Audio recording uses the device microphone through AVFoundation. Transcription is performed on device with WhisperKit/Core ML after a WhisperKit model is installed and loaded. The app does not call a cloud transcription API or send recordings to a third-party transcription vendor in the inspected code path.

The app may use the network for:

- Downloading WhisperKit Core ML model files from the configured WhisperKit model repository when the selected model is not already local.
- iCloud/CloudKit sync when the user has iCloud available for this app.
- CloudKit remote notification registration for sync updates.
- Opening the external WhisperKit model page from Settings when the user taps View Models.

If iCloud is available, SwiftData is configured with automatic CloudKit sync for `VoiceNote` records, and audio files are stored in the app's iCloud Documents container `iCloud.com.hellotaotao.Voicely`. If iCloud is unavailable, audio files fall back to the local app documents directory. Transcripts, note metadata, and transcription coordination fields are represented in the SwiftData `VoiceNote` model.

The app sets `ITSAppUsesNonExemptEncryption` to `false` in `Info.plist`. Based on the inspected project, Voicely does not implement custom non-exempt encryption. It relies on standard Apple platform networking/security for iCloud, CloudKit, and model downloads.

No login is required to test the core app. To test transcription, install/load a WhisperKit model in Settings, make a short recording, then open the note to view or re-run transcription. iCloud sync behavior requires an iCloud account and iCloud availability on the test device.

## App Privacy Nutrition Label Draft

### Tracking

- Data used to track users: No.
- Third-party advertising tracking: Not observed in source.
- IDFA or advertising SDKs: Not observed in source.

### Data Types To Consider Disclosing

| App Store data type | Likely answer | Purpose | Linked to user | Notes |
| --- | --- | --- | --- | --- |
| Audio Data | Yes, if using conservative disclosure | App Functionality | Potentially yes when synced through user's iCloud | User-created recordings are stored locally or in the user's iCloud Documents container when available. |
| Other User Content | Yes | App Functionality | Potentially yes when synced through CloudKit | Includes note titles, transcripts, transcription errors/status, and transcript edits. |
| Identifiers | Possibly | App Functionality | Possibly | The app creates a local UUID-style device identity for transcription ownership coordination. It is not an advertising identifier. Confirm whether to disclose based on App Store Connect guidance. |
| Diagnostics | No, unless Apple crash reporting or another SDK is added | N/A | N/A | No custom analytics or diagnostics collection was observed. |
| Contact Info, Location, Purchases, Financial Info, Contacts, Browsing History, Search History | No, based on inspected source | N/A | N/A | Not observed in current code. |

### Storage And Sync Explanation

- Recordings are user-created audio files.
- Transcripts and note metadata are stored in SwiftData.
- SwiftData is configured for automatic CloudKit sync outside tests.
- Audio files use iCloud Documents when `CloudStorageManager` can access the iCloud container; otherwise they use local app storage.
- WhisperKit model files are downloaded and stored locally in the app documents area. Users can delete downloaded models in Settings.
- The custom transcription prompt and selected language/model settings are stored locally via `UserDefaults`.

### Conservative Privacy Label Recommendation

For a first official release, use conservative App Privacy answers:

- Disclose User Content: Audio Data and Other User Content.
- Purpose: App Functionality.
- Tracking: No.
- Data shared with third-party advertisers/data brokers: No.
- Data used for advertising: No.
- Data may be linked to user: Yes if CloudKit/iCloud sync is considered linked to the user's Apple ID. Confirm with App Store privacy guidance and counsel.

## Permission Purpose Strings And Rationale

Current generated Info.plist build-setting strings:

- `NSMicrophoneUsageDescription`: "This app needs access to your microphone to record voice notes for transcription."
- `NSSpeechRecognitionUsageDescription`: "This app uses speech recognition to transcribe your voice notes."

Recommended App Review rationale:

- Microphone access is required only when the user records audio.
- Recorded audio is used to create a voice note and provide local transcription.
- The app uses WhisperKit/Core ML for transcription rather than a cloud transcription service.
- Speech recognition wording exists in build settings, but the inspected implementation does not use Apple's Speech framework. Consider updating the string before final archive if the product owner wants clearer wording, for example: "Voicely uses on-device transcription to turn your recordings into text."

## Export Compliance Notes

Current source sets `ITSAppUsesNonExemptEncryption` to `false` in `Voicely/Info.plist`. The App Store Connect export compliance answer should be consistent with that only if no new encryption code or encrypted communication features are added before archive.

Suggested answer: the app does not use non-exempt encryption. It uses standard Apple platform services for iCloud/CloudKit and standard network transport for model downloads.

## Review Risks To Check Before Submission

- Confirm the final production archive has production App Store signing and production CloudKit/APNs entitlements, even though the checked-in entitlements file currently contains development APNs values.
- Confirm CloudKit schema/container are ready for production if the release build will sync data.
- Confirm support URL and privacy policy/support pages are live.
- Confirm App Privacy answers with a conservative interpretation of iCloud sync.
- Confirm model downloads work on a clean device and that the app has a clear path when no model is loaded.
