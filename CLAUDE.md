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

# Run specific test file
xcodebuild -scheme Voicely -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:VoicelyTests/TranscriptionServiceTests test

# Archive for iOS (auto-appears in Xcode Organizer)
xcodebuild -scheme Voicely -configuration Release -destination 'generic/platform=iOS' archive

# Archive for Mac Catalyst (auto-appears in Xcode Organizer)
xcodebuild -scheme Voicely -configuration Release -destination 'generic/platform=macOS,variant=Mac Catalyst' archive

# Open in Xcode
open Voicely.xcodeproj
```

If xcodebuild fails with "scheme not found", open Xcode and mark the `Voicely` scheme as shared (Product > Scheme > Manage Schemes).

## Architecture

**Voicely** is a SwiftUI iOS/Mac Catalyst app for voice recording with on-device transcription using WhisperKit.

### Core Services (all `@MainActor`)

- **ModelManager** – Downloads, loads, and manages WhisperKit CoreML models. Persists selected model in UserDefaults. Posts `Notification.Name.modelLoadedNotification` when ready.
- **TranscriptionService** – Orchestrates transcription through the selected engine (`TranscriptionEngineMode`): Qwen3-ASR (MLX, default) or WhisperKit. Supports cancellation, progress smoothing, and batch processing of pending notes.
- **Qwen3ASRModelStore / Qwen3ModelDownloadController** (`Qwen3TranscriptionEngine.swift`) – Owns the Qwen3-ASR 0.6B (4-bit MLX) model: download to Application Support (hub layout), offline load, warm-up, serialized inference. The engine mode defaults to Qwen3 on MLX-capable hardware (A14/M1+, real devices only); the simulator and older chips resolve to WhisperKit. Qwen3 transcripts have chunk-level (not word-level) timings.
- **AudioRecordingService** – Handles AVAudioRecorder, microphone permissions, and recording state. Saves audio to iCloud Documents.
- **AudioPlayerService** – Plays back recorded audio files.
- **CloudStorageManager** – Singleton managing iCloud Documents for audio file sync and NSMetadataQuery for sync status.
- **CloudKitSyncMonitor** – Monitors SwiftData/CloudKit sync events and exposes sync state to the UI.

### Data Model (SwiftData)

- **VoiceNote** (`Item.swift`) – The single `@Model` entity representing a voice recording with transcription state, progress, and audio file path.
- The ModelContainer uses `.automatic` CloudKit database mode for cross-device sync.

### Key Dependencies

- **WhisperKit** (argmaxinc) – On-device speech recognition via CoreML
- **Qwen3ASR** (`Vendor/speech-swift`, vendored soniqo/speech-swift subset with a Mac Catalyst patch) – On-device Qwen3-ASR via MLX
- **mlx-swift** (ml-explore) – MLX runtime for the Qwen3 engine (GPU-only; no simulator support)
- **swift-transformers** (huggingface) – Tokenization support

### Views

- **ContentView** – Main recording/playback UI with note list
- **SettingsView** – Model selection, language, custom prompts
- **WhisperKitModelsView** – Model download and management UI
- **CloudKitSettingsView** – iCloud sync configuration
- **SyncStatusView** – Visual sync status indicator
- **BenchmarkView** – Performance benchmarking UI

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
