# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Development Target: Mac First

Develop and verify on the Mac (Catalyst) build by default. Build, run unit tests, and check changes in the running Mac app; do not run the iOS Simulator or ask for an iPhone to be connected during day-to-day work. iPhone compatibility and performance (CoreML path, background/lock-screen behavior, memory) get dedicated testing shortly before a release. Record iPhone-specific concerns in `docs/stable-roadmap.md` instead of treating them as blockers for the current change.

## Build & Test Commands

The speech model ships inside the app. Run `scripts/fetch-speech-models.sh` once per machine: it puts the pinned models in `Models/` (not in git), and the "Embed Speech Model" build phase copies the MLX weights into the Mac app and the CoreML models into the iPhone/iPad app as `SpeechModel/`. Builds fail with a pointer to the script when `Models/` is missing.

```bash
# Build for Mac (Catalyst) — the default development target
xcodebuild -scheme Voicely -configuration Debug -destination 'platform=macOS,variant=Mac Catalyst' build

# Run unit tests on Mac (UI tests are not supported on Mac Catalyst)
xcodebuild -scheme Voicely -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:VoicelyTests test

# Run specific test file on Mac
xcodebuild -scheme Voicely -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:VoicelyTests/TranscriptionServiceTests test

# Pre-release iPhone checks only: build for iOS Simulator
xcodebuild -scheme Voicely -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' build

# Pre-release iPhone checks only: run all tests on iOS Simulator (unit + UI)
xcodebuild -scheme Voicely -destination 'platform=iOS Simulator,name=iPhone 17' test

# Archive for iOS (auto-appears in Xcode Organizer)
xcodebuild -scheme Voicely -configuration Release -destination 'generic/platform=iOS' archive

# Archive for Mac Catalyst (auto-appears in Xcode Organizer). Apple silicon only: the
# vendored speech-swift uses Float16, which Intel Mac Catalyst lacks, and MLX needs Apple silicon.
# ARCHS must be passed here because project build settings do not reach Swift package targets.
xcodebuild -scheme Voicely -configuration Release -destination 'generic/platform=macOS,variant=Mac Catalyst' ARCHS=arm64 archive

# Open in Xcode
open Voicely.xcodeproj
```

If xcodebuild fails with "scheme not found", open Xcode and mark the `Voicely` scheme as shared (Product > Scheme > Manage Schemes).

## Architecture

**Voicely** is a SwiftUI iOS/Mac Catalyst app for voice recording with on-device transcription using Qwen3-ASR 0.6B.

### Core Services (all `@MainActor`)

- **ModelManager** – Loads the Qwen3-ASR model that ships inside the app and publishes its state. One model per device. Posts `Notification.Name.modelLoadedNotification` when ready.
- **Qwen3ASRModelStore** (`Qwen3TranscriptionEngine.swift`, an actor) – Owns the loaded model and runs every inference. `Qwen3Backend` picks the runtime: MLX on the GPU on Apple-silicon Macs, CoreML on CPU + Neural Engine everywhere else (iOS takes the GPU away from a backgrounded app). Audio is sliced at neural-VAD cuts to ≤29 s (`Qwen3SliceLimits`) before it reaches the model; the Mac uses the 8-bit MLX weights, because the 4-bit ones drop text on long slices.
- **TranscriptionService** – Orchestrates transcription via the model store. Depends on ModelManager for the loaded model. Supports cancellation, progress smoothing, and batch processing of pending notes.
- **AudioRecordingService** – Handles AVAudioRecorder, microphone permissions, and recording state. Saves audio to iCloud Documents.
- **AudioPlayerService** – Plays back recorded audio files.
- **CloudStorageManager** – Singleton managing iCloud Documents for audio file sync and NSMetadataQuery for sync status.
- **CloudKitSyncMonitor** – Monitors SwiftData/CloudKit sync events and exposes sync state to the UI.

### Data Model (SwiftData)

- **VoiceNote** (`Item.swift`) – The single `@Model` entity representing a voice recording with transcription state, progress, and audio file path.
- The ModelContainer uses `.automatic` CloudKit database mode for cross-device sync.

### Key Dependencies

- **speech-swift** (vendored subset in `Vendor/speech-swift`, see its `PATCHES.md`) – Qwen3-ASR on MLX and CoreML
- **mlx-swift** (ml-explore) – GPU runtime for the Mac backend; building it needs Xcode's Metal Toolchain component (`xcodebuild -downloadComponent MetalToolchain`)
- **swift-transformers** (huggingface) – used inside speech-swift; the app itself never downloads a model

### Views

- **ContentView** – Main recording/playback UI with note list
- **SettingsView** – Model status, speech language, diagnostics
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

## Roadmap and To Do

`docs/stable-roadmap.md` is the single source of truth for the release order (phases 一~七), all open tasks, and the verified list of what is already done. If any other document conflicts with it, the roadmap wins. Add new to-dos there, not to `AGENTS.md`.

Historical execution and verification records live in `docs/roadmap-log.md`.
