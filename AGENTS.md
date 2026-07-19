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

## To Do — Code Review Findings (2026-07-06)

### High severity
- ~~Make cancellation actually stop a segmented (>30s) transcription~~ — DONE (2026-07-07): `TranscriptionService` now keeps a sticky per-note `cancelledRunNoteIDs` mark (the old `cancelRequested` flag is consumed by whichever slice observes it, so it could never stop the outer loop); the batch loop checks it every boundary and `.cancelled` exits immediately instead of falling into bisection salvage. Sidecar/working copy are kept so the run stays resumable. Tests: `cancelledSliceStopsTheRunWithoutSalvaging`, `userCancelMidRunStopsTheLoop`.
- ~~Keep `wordTimings` in lockstep with the sanitized transcript~~ — DONE (2026-07-06): `TranscriptAssembler` now filters (text, words) pairs as one unit at whisper-segment granularity; sanitized words are the single source of truth and `note.transcription` is a derived cache written only through `VoiceNote.setTranscript(text:words:)` (invariant: `text == words.joined()`); all three paths (single-pass, segmented, live) accumulate raw `TranscriptPiece`s and assemble at the outer level, so cross-slice dedup/overlap-merge now applies to words too. Piece separators ride inside the preceding token (`"…word\n"`), giving the tappable view paragraph breaks. A DEBUG log (`🔁 [Assembler] duplicate piece dropped`) records time ranges + token density of dropped duplicates — collect these from real recordings to design the phase-2 timestamp/VAD-verified dedup (which can then also stop deleting genuine repeats).
- ~~Give the PCM temp file a per-call unique name~~ — DONE (2026-07-07): `AudioRecordingService.makePCMTemporaryURL(now:)` appends a UUID nonce (matching the segment temp-file fix in e7562df). Test: `RecordingTempFileNamingTests`.
- ~~Guard deletion of the note that is currently being recorded~~ — DONE (2026-07-07): `RecordingSession.isRecording(_:)` identifies the in-progress note and `deleteNoteAndAudio` refuses to delete it (both entry points — swipe and row menu — route through that function). Test: `isRecordingNoteIdentifiesTheInProgressNoteOnly`.
- ~~Fix `TappableTranscriptView` rebuild detection~~ — DONE (2026-07-06): rebuild now compares the full `words` array (`Equatable`; identical-storage fast path keeps the 10 Hz call cheap). Regression test: `TappableTranscriptViewTests`.

### Medium severity
- Isolate 20 Hz transcription-progress updates from the note list and detail view: progress smoothing writes `@Published` state on the shared `TranscriptionService` every ~50 ms, re-rendering the whole `ForEach` and the open detail view for the entire run. Move progress reads into a small child view. (`Voicely/TranscriptionService.swift:1019-1048`, `Voicely/ContentView.swift:442-467`)
- Broaden the `NSMetadataQuery` predicate beyond `*.m4a`/`*.wav` so imported formats (mp3, caf, aac, …) are reflected in sync status. (`Voicely/CloudStorageManager.swift:564-568`)
- Move `forceDownloadAll()`'s directory scan and per-file iCloud status checks off the MainActor (mirror the `deleteFile` Task.detached pattern). (`Voicely/CloudStorageManager.swift:686-707`)
- End orphaned Live Activities on launch by enumerating `Activity<RecordingActivityAttributes>.activities`; today a crash/force-quit while recording leaves the Dynamic Island stuck on "recording". (`Voicely/RecordingLiveActivityController.swift`)
- Protect `audioFile`/`converter` handoff between the real-time tap thread and MainActor teardown with the existing `sharedState` lock instead of `nonisolated(unsafe)` + assumed `removeTap` ordering. (`Voicely/AudioRecordingService.swift:334-341,485,521`)
- Stop doing per-note `FileManager.fileExists` work inside `BenchmarkView.body`; cap candidates before the availability check and cache results. (`Voicely/BenchmarkView.swift:115-137`)
- Include subview content width in `WrappingFlowLayout`'s cache key; count+width alone misses pill text changes and can leave clipped/overlapping badges. (`Voicely/ContentView.swift:2465-2474`)

### Low severity / cleanup
- Remove or rewire dead lease-heartbeat code (`beginLocalTranscription`, `startLeaseHeartbeat` are never called since the segmented-transcriber refactor). (`Voicely/TranscriptionService.swift:784-832`)
- Confirm `CloudKitSettingsView` is unreachable and delete it if so. (`Voicely/CloudKitSettingsView.swift`)

### Pre-existing issues found during Mac verification (2026-07-06, all reproduced on pre-refactor baseline too)
- The entire large-v3-v20240930 (new-gen turbo) family returns EMPTY decodes on this Mac (Catalyst): A/B test 2026-07-07 with the same 46 s file — quantized 626MB/turbo_632MB AND the full-precision 1.62 GB build all blank-decode (~29 s slice returns `0 segments` in 0.3–1 s), while the previous-generation `openai_whisper-large-v3_turbo_954MB` transcribes it word-perfectly (and small/base work). So it's NOT quantization — it's the v20240930 model builds × this Mac's CoreML/ANE. Full-precision also takes ~15 min of first-load ANE specialization, impractical as a product option. Pending: does 626MB work on iPhone (A-series ANE)? Decision: swap the Pro tier to 954MB at least on Mac; if iPhone also fails, drop the v20240930 variants entirely. (`Voicely/ModelManager.swift` curatedModels + proDefaultIdentifier)
- The custom prompt (Settings) is injected into EVERY whisper slice (`Using custom prompt: Claude Code` per slice) and leaks verbatim into output on low-information audio — the classic whisper initial-prompt parroting hallucination ("claude", "claude code" scattered through noisy transcripts). Consider: only injecting the prompt when it contains domain vocabulary the user explicitly wants biased, warning in Settings, or dropping the prompt for slices whose VAD confidence is marginal. (`Voicely/TranscriptionService.swift`, `Voicely/SettingsView.swift`)
- "Tap to retry" on a failed import is a dead button: imports keep no audio by design (throwaway working copy, removed on completion — including failed completion), so a retry has nothing to transcribe and silently does nothing. Either keep the working copy while `transcriptionOutcome == .failed`, or hide the retry affordance for audio-less notes. (`Voicely/SegmentedAudioTranscriber.swift:152-153`, `Voicely/ContentView.swift`)
- Importing right after launch races model loading: the run starts before WhisperKit finishes loading, every slice returns modelUnavailable, and the note completes as failed instead of waiting/queueing. (`Voicely/ContentView.swift` onOpenURL path, `Voicely/TranscriptionService.swift`)
- The four failing `VoicelyUITests` cases (`testEmptyLibraryShellShowsPrimaryRecordingPath`, `testLaunchShowsLibraryShell`, `testQueuedRecordingAllowsManualTranscribePrompt`, `testSeededRecordingTranscribePromptRoutesToSettings`) fail identically on the pre-refactor baseline — stale tests, not regressions. Update or remove them. (`VoicelyUITests/VoicelyUITests.swift`)
