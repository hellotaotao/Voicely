# Repository Guidelines

## Project Structure & Module Organization
- `Voicely/` contains the SwiftUI app source, services (recording, transcription, CloudKit), and models (SwiftData).
- `VoicelyTests/` holds unit tests using the Swift Testing framework.
- `VoicelyUITests/` holds UI tests using XCTest.
- `Voicely.xcodeproj/` is the Xcode project definition.
- `build/` is build output and can be ignored.

## Build, Test, and Development Commands
- `open Voicely.xcodeproj` opens the project in Xcode for running on device/simulator.
- `xcodebuild -scheme Voicely -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' build` builds for iOS Simulator.
- `xcodebuild -scheme Voicely -configuration Debug -destination 'platform=macOS,variant=Mac Catalyst' build` builds for Mac.
- `xcodebuild -scheme Voicely -destination 'platform=iOS Simulator,name=iPhone 17' test` runs all tests (unit + UI) on iOS Simulator.
- `xcodebuild -scheme Voicely -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:VoicelyTests test` runs unit tests on Mac (UI tests are not supported on Mac Catalyst).
- `xcodebuild -scheme Voicely -configuration Release -destination 'generic/platform=iOS' archive` archives for iOS (auto-appears in Xcode Organizer).
- `xcodebuild -scheme Voicely -configuration Release -destination 'generic/platform=macOS,variant=Mac Catalyst' archive` archives for Mac Catalyst (auto-appears in Xcode Organizer).

If the scheme is not shared, open Xcode and mark the `Voicely` scheme as shared before using `xcodebuild`.

## Coding Style & Naming Conventions
- Indentation uses 4 spaces; keep SwiftUI views and services formatted consistently.
- Use Swift naming conventions: `UpperCamelCase` for types, `lowerCamelCase` for variables/functions.
- Keep view files focused (one primary view per file when possible) and name files after their main type (e.g., `SettingsView.swift`).

## Testing Guidelines
- Unit tests use Swift Testing (`import Testing`) with `@Test` functions in `VoicelyTests/`.
- UI tests use XCTest in `VoicelyUITests/`.
- Name tests with `test...` or clear `@Test` function names describing behavior.

## Commit & Pull Request Guidelines
- Commits use short, imperative sentences (e.g., “Add CloudKit sync status monitoring”).
- PRs should include a concise description, key changes, and testing notes.
- For UI changes, include simulator screenshots or a short screen recording.

## Configuration & Security Notes
- CloudKit/iCloud features are used; avoid checking in secrets or local credentials.
- Keep `Info.plist` changes minimal and documented in PRs when permissions or entitlements change.

## To Do
- Validate the new iOS system recording integrations on device: Live Activity / Dynamic Island recording status and the Start Voicely Recording App Shortcut / Action Button assignment path. (`Voicely/RecordingLiveActivityController.swift`, `VoicelyWidgets/`, `Voicely/StartRecordingIntent.swift`, `Voicely/VoicelyDeepLink.swift`)
- Add meeting-length recording controls as the next major product step: let users choose an auto-stop duration when starting recording, support precise durations such as 30/35/41/60 minutes, show a prominent countdown warning a few minutes before stopping, offer extend/stop-now choices, and later explore smart auto-stop when farewell phrases plus silence indicate the meeting has ended. (`Voicely/ContentView.swift`, `Voicely/AudioRecordingService.swift`, `Voicely/RecordingActivityAttributes.swift`)
- Explore Apple Watch companion support later: start with Watch as an iPhone recording remote/status surface before considering direct Watch microphone recording and sync. (future watchOS target / WatchConnectivity files)
- Replace simulated transcription progress with real progress reporting (e.g., integrate WhisperKit callbacks / segment progress) and reflect in UI. (`Voicely/TranscriptionService.swift`, `Voicely/ContentView.swift`)
- Fix `processPendingTranscriptions` so notes aren't skipped when another transcription is active; wait/retry or queue work. (`Voicely/TranscriptionService.swift`)
- Ensure the simulated progress task is always cancelled on early exit/error/cancellation. (`Voicely/TranscriptionService.swift`)
- Wire `showLoadModelPrompt` to prompt users when attempting transcription without a loaded model, and route to Settings. (`Voicely/ContentView.swift`, `Voicely/SettingsView.swift`)
- Handle iCloud audio downloads more robustly (wait for download completion, retry load, and surface status in the UI). (`Voicely/AudioPlayerService.swift`, `Voicely/ContentView.swift`)
- Start the metadata query automatically when iCloud is enabled so sync status updates without manual refresh. (`Voicely/CloudStorageManager.swift`)
- Remove or use `currentRecordingPath` if it serves no purpose. (`Voicely/ContentView.swift`)
- Add a test for pending transcription processing while a transcription is already in progress. (`VoicelyTests/TranscriptionServiceTests.swift`)
- Gate verbose debug logging behind `#if DEBUG` to reduce production log noise. (`Voicely/AudioRecordingService.swift`, `Voicely/CloudStorageManager.swift`, `Voicely/AudioPlayerService.swift`, `Voicely/VoicelyApp.swift`)
