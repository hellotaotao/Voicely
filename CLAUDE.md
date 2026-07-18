# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
# Build for iOS Simulator
xcodebuild -scheme Voicely -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' build

# Build for Mac (Catalyst)
xcodebuild -scheme Voicely -configuration Debug -destination 'platform=macOS,variant=Mac Catalyst' build

# Run all tests on iOS Simulator (unit + UI)
xcodebuild -scheme Voicely -destination 'platform=iOS Simulator,name=iPhone 17' test

# Run unit tests on Mac (UI tests are not supported on Mac Catalyst)
xcodebuild -scheme Voicely -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:VoicelyTests test

# Run a specific test file
xcodebuild -scheme Voicely -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:VoicelyTests/TranscriptionServiceTests test

# Archive (auto-appears in Xcode Organizer)
xcodebuild -scheme Voicely -configuration Release -destination 'generic/platform=iOS' archive
xcodebuild -scheme Voicely -configuration Release -destination 'generic/platform=macOS,variant=Mac Catalyst' archive

# Open in Xcode
open Voicely.xcodeproj
```

If xcodebuild fails with "scheme not found", open Xcode and mark the `Voicely` scheme as shared (Product > Scheme > Manage Schemes).

## Versioning

`Config/Version.xcconfig` is the single source of truth for `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`. Bump versions there only — both the app and the `VoicelyWidgets` extension inherit it (the App Store requires the two to match). Release history is tracked in `CHANGELOG.md`.

## Architecture

**Voicely** is a SwiftUI iOS/Mac Catalyst app for voice recording with fully on-device transcription using WhisperKit. Targets: `Voicely` (app), `VoicelyWidgets` (widget/Live Activity extension), `VoicelyTests`, `VoicelyUITests`.

### Recording pipeline

- **AudioRecordingService** – `AVAudioEngine` writing PCM to a CAF file during recording; converted to M4A in the background after stop. Handles mic permissions and system audio interruptions (posts `.recordingInterruptedBySystem`).
- **RecordingSession** – Owns the lifecycle of one recording: the note being recorded, the incremental-transcription coordinator, and start/pause/resume/stop control flow. Talks to the recorder through the `RecordingAudioControlling` protocol so tests can inject a fake recorder.
- **IncrementalTranscriptionCoordinator** – Live transcription while recording: extracts ~29 s batches from the growing PCM file, choosing cut points with neural VAD, and accumulates text segment by segment.

### Transcription pipeline

- **ModelManager** – Downloads, loads, and manages WhisperKit CoreML models; persists the selection in UserDefaults and posts `.modelLoadedNotification` when ready. Checks bundled model locations before downloading (see `docs/bundled-whisper-model.md`). Filters the model list: distil models and `medium.en` are excluded; remaining `.en` models get an "(English Only)" tag in UI (policy in `todo.md`; match with `contains(".en")`, not `hasSuffix`, because of quantized variants like `small.en_217MB`).
- **TranscriptionService** – Orchestrates WhisperKit transcription; depends on ModelManager. Supports cancellation, progress smoothing, and batch processing of pending notes.
- **SegmentedAudioTranscriber** – Transcribes complete audio files (imports, re-transcribe). Files ≤30 s run in one pass; longer files are sliced into ≤29 s neural-VAD segments with resumable progress.
- **SegmentProgressStore** – Durable JSON sidecar per note for in-flight segmented transcriptions, stored in a non-synced, backup-excluded directory so half-done work never reaches iCloud.
- **NeuralSpeechAnalyzer** / **SileroNeuralVoiceActivityDetector** – Neural VAD over the bundled `silero_vad.mlmodelc` CoreML model. Deliberately conservative: uncertain frames count as speech so user audio is never silently dropped.
- **LocalTranscriptFinalizer** / **TranscriptSanitizer** – Deterministic on-device transcript cleanup (non-speech markers, duplicate lines, whitespace).
- **VoiceNoteAutoTitle** – Derives a note title from the transcript start, sized by display width (CJK counts as 2 columns) so Chinese and English titles fill similar space.

### Sync & data

- **VoiceNote** (`Item.swift`) – The single SwiftData `@Model`, holding transcription state, progress, and audio file path. The ModelContainer uses `.automatic` CloudKit mode — except under tests, where `AppRuntime.isRunningTests` switches to an in-memory store with CloudKit disabled.
- **CloudStorageManager** – Singleton managing iCloud Documents for audio files. Audio downloads are on-demand via `prepareFileForReading` (playback/transcription/benchmark), not bulk.
- **CloudKitSyncMonitor** – Monitors SwiftData/CloudKit sync events and exposes sync state to the UI.

### System integration

- **RecordingLiveActivityController** + `VoicelyWidgets/` – Live Activity / Dynamic Island recording status. `RecordingActivityAttributes.swift` and `ToggleRecordingPauseIntent.swift` exist as intentionally separate app and widget copies with the same type names — the widget copy conforms to `ActivityAttributes` / performs the widget-side action; keep their `ContentState` shapes in sync since they encode/decode across processes.
- **StartRecordingIntent** – App Intent + App Shortcuts (Siri, Action Button).
- **VoicelyDeepLink** – `voicely://record` and `voicely://recording/toggle-pause` URL handling.
- **QuickAction** (`VoicelyApp.swift`) – Home Screen quick action to start recording, using a persisted pending flag + NotificationCenter so a cold launch isn't missed.
- **RecordingControlCommandCenter** – Shared entry point for pause/resume toggles from intents and quick actions.

### Views

**ContentView** (main list + recording/playback, largest file), **SettingsView**, **WhisperKitModelsView**, **CloudKitSettingsView**, **SyncStatusView**, **BenchmarkView**, **DiagnosticsView**, **FirstLaunchOnboarding**. Shared design tokens and components live in `DesignSystem.swift` (`VoicelyTheme`, `SurfaceCard`, `PillBadge`, etc.) — use these rather than ad-hoc styling.

### Key Dependencies

- **WhisperKit** (argmaxinc) – On-device speech recognition via CoreML
- **swift-transformers** (huggingface) – Tokenization support

## Testing

- Unit tests use **Swift Testing** (`import Testing`, `@Test` functions) in `VoicelyTests/`; UI tests use XCTest in `VoicelyUITests/`.
- `AppRuntime.isRunningTests` makes the app use an in-memory store, skip CloudKit, and skip notification registration — no mocking needed for app boot.
- Services are made testable via protocol injection (e.g. `RecordingAudioControlling` for the recorder) and overridable closures (e.g. `SegmentedAudioTranscriber.transcribeSegmentOutcome`, `nextCutFrame`); mock ModelManager by subclassing and overriding `isModelLoaded()`.
- UI tests seed data through environment variables (`VOICELY_UI_TEST_SEED_NOTE=1` plus `VOICELY_UI_TEST_NOTE_*`) and locate elements via `AccessibilityIdentifiers.swift`.
- A Live Activity preview can be forced in DEBUG builds with `VOICELY_SHOW_RECORDING_ACTIVITY_PREVIEW=1`.
- `scripts/perf_compare.py` is a standalone benchmark for sync/migration optimizations.

## Coding Conventions

- 4-space indentation; one primary view per file, named after the main type.
- SwiftUI views and services are `@MainActor`.
- Logging goes through `debugLog()` (`DebugLog.swift`), which compiles out of release builds; messages use emoji prefixes (`🔍`, `✅`, `❌`, `⚠️`).
- Doc comments explain *why* a design choice was made (see `VoiceNoteAutoTitle`, `SegmentProgressStore`) — follow that style for non-obvious behavior.
- Commits use short, imperative sentences; `feat:`/`fix:`/`chore:` prefixes are common in recent history.

## Planning & Docs

- `todo.md` – Active product/engineering backlog with investigation notes (written in Chinese); check it before starting feature work — decisions and root-cause analyses are recorded there.
- `AGENTS.md` – Repository guidelines plus an older tracked to-do list.
- `docs/superpowers/` – Design specs and implementation plans for major features (e.g. segmented long-audio transcription).
- `docs/app-store-release/` – App Store metadata, review notes, and release checklist.
- `docs/bundled-whisper-model.md` – How to package the built-in default WhisperKit model.
