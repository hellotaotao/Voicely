# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
# Build for iOS Simulator
xcodebuild -scheme Voicely -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 15' build

# Run all tests (unit + UI)
xcodebuild -scheme Voicely -destination 'platform=iOS Simulator,name=iPhone 15' test

# Run specific test file
xcodebuild -scheme Voicely -destination 'platform=iOS Simulator,name=iPhone 15' test -only-testing:VoicelyTests/TranscriptionServiceTests

# Open in Xcode
open Voicely.xcodeproj
```

If xcodebuild fails with "scheme not found", open Xcode and mark the `Voicely` scheme as shared (Product > Scheme > Manage Schemes).

## Architecture

**Voicely** is a SwiftUI iOS app for voice recording with on-device transcription using WhisperKit.

### Core Services (all `@MainActor`)

- **ModelManager** – Downloads, loads, and manages WhisperKit CoreML models. Persists selected model in UserDefaults. Posts `Notification.Name.modelLoadedNotification` when ready.
- **TranscriptionService** – Orchestrates transcription via WhisperKit. Depends on ModelManager for the loaded model. Supports cancellation, progress smoothing, and batch processing of pending notes.
- **AudioRecordingService** – Handles AVAudioRecorder, microphone permissions, and recording state. Saves audio to iCloud Documents.
- **AudioPlayerService** – Plays back recorded audio files.
- **CloudStorageManager** – Singleton managing iCloud Documents for audio file sync and NSMetadataQuery for sync status.
- **CloudKitSyncMonitor** – Monitors SwiftData/CloudKit sync events and exposes sync state to the UI.

### Data Model (SwiftData)

- **VoiceNote** (`Item.swift`) – The single `@Model` entity representing a voice recording with transcription state, progress, and audio file path.
- The ModelContainer uses `.automatic` CloudKit database mode for cross-device sync.

### Key Dependencies

- **WhisperKit** (argmaxinc) – On-device speech recognition via CoreML
- **swift-transformers** (huggingface) – Tokenization support

### Views

- **ContentView** – Main recording/playback UI with note list
- **SettingsView** – Model selection, language, custom prompts
- **CloudKitSettingsView** – iCloud sync configuration
- **SyncStatusView** – Visual sync status indicator

## Testing

- Unit tests use **Swift Testing** (`import Testing`, `@Test` functions) in `VoicelyTests/`
- UI tests use XCTest in `VoicelyUITests/`
- Mock ModelManager by subclassing and overriding `isModelLoaded()`

## Coding Conventions

- 4-space indentation
- One primary view per file, named after the main type (e.g., `SettingsView.swift`)
- SwiftUI views and services are `@MainActor`
- Debug logging uses emoji prefixes (`🔍`, `✅`, `❌`, `⚠️`) – gate verbose logs behind `#if DEBUG`

## Known Issues (from AGENTS.md To Do)

See `AGENTS.md` for tracked improvements including: Share Sheet import, real WhisperKit progress callbacks, transcription queue handling, and iCloud download robustness.
