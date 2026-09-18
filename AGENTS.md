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

## Roadmap and To Do

All roadmap items and open tasks live in a single file: [`docs/stable-roadmap.md`](docs/stable-roadmap.md).
It is the source of truth — if any other document disagrees with it, the roadmap wins.
Do not add new to-dos here; add them under section 四 (跨阶段待办) of the roadmap.
Historical execution and verification records are in [`docs/roadmap-log.md`](docs/roadmap-log.md).
