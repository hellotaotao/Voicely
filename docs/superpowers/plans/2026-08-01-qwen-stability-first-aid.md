# Qwen Stability First Aid Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Make each transcription run internally immutable, keep Qwen timing claims honest, and stop repetition cleanup from deleting genuine repeated speech.

**Architecture:** Add a Codable run-configuration value and a single-owner run token in `TranscriptionService`. Pass the captured value through segmented and live coordinators, persist it in sidecars, and render tappable transcript UI only for true word timing. Keep repetition filtering timestamp-aware and use a conservative detector for catastrophic loops.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, AVFoundation, Swift Testing, WhisperKit, MLX Qwen3-ASR.

---

## Status: COMPLETE (verified 2026-08-29)

Tasks 1–6 landed in the working tree on 2026-08-01. Task 7 verification was run
on 2026-08-29 before committing:

- Mac Catalyst unit tests: 238 cases pass (run twice).
- Mac Catalyst Debug build: succeeds, no warnings.
- iOS Simulator Debug build (iPhone 17 Pro): succeeds.
- `git diff --check`: clean.

**Still open — this plan does not close it:** real-device Qwen transcription
quality. The plan called that out as a separate release gate and it has not been
run. The 0.24.0 release therefore ships with WhisperKit as the default engine and
Qwen3 as an opt-in experimental choice.

---

### Task 1: Verify the existing emergency fixes

**Files:**
- Modify: `Voicely/Qwen3TranscriptionEngine.swift`
- Modify: `Voicely/SegmentedAudioTranscriber.swift`
- Modify: `Voicely/RecordingSession.swift`
- Test: `VoicelyTests/Qwen3TranscriptionEngineTests.swift`
- Test: `VoicelyTests/SegmentedAudioTranscriberTests.swift`
- Test: `VoicelyTests/RecordingSessionTests.swift`

- [x] Run the three focused test suites and record the passing baseline.
- [x] Confirm the PCM tests exercise both the direct 16 kHz path and converter path.
- [x] Confirm transient engine failures stop a segmented run without bisection or placeholders.
- [x] Confirm completed Qwen live transcription stamps the Qwen model identifier.

Run:

```bash
xcodebuild -scheme Voicely -destination 'platform=macOS,variant=Mac Catalyst' \
  -only-testing:VoicelyTests/Qwen3AudioPCMTests \
  -only-testing:VoicelyTests/SegmentedAudioTranscriberTests \
  -only-testing:VoicelyTests/RecordingSessionTests test
```

Expected: all selected tests pass.

### Task 2: Add an immutable run configuration

**Files:**
- Create: `Voicely/TranscriptionRunConfiguration.swift`
- Modify: `Voicely/Qwen3TranscriptionEngine.swift`
- Modify: `Voicely/TranscriptionService.swift`
- Test: `VoicelyTests/TranscriptionRunConfigurationTests.swift`
- Test: `VoicelyTests/TranscriptionServiceTests.swift`

- [x] Write tests for Qwen and Whisper capture values and Codable round-trip.
- [x] Run the tests and verify they fail because the type and capture API do not exist.
- [x] Add `TranscriptionTimingGranularity` and `TranscriptionRunConfiguration`.
- [x] Change `TranscribeImpl` to receive the captured configuration.
- [x] Route Qwen/Whisper, model identifiers, language, prompt, and telemetry through that configuration.
- [x] Run the focused tests until they pass.

Run:

```bash
xcodebuild -scheme Voicely -destination 'platform=macOS,variant=Mac Catalyst' \
  -only-testing:VoicelyTests/TranscriptionRunConfigurationTests \
  -only-testing:VoicelyTests/TranscriptionServiceTests test
```

Expected red: missing run-configuration symbols. Expected green: all selected tests pass.

### Task 3: Persist configuration and freeze segmented/live runs

**Files:**
- Modify: `Voicely/SegmentProgressStore.swift`
- Modify: `Voicely/SegmentedAudioTranscriber.swift`
- Modify: `Voicely/IncrementalTranscriptionCoordinator.swift`
- Modify: `Voicely/RecordingSession.swift`
- Test: `VoicelyTests/SegmentProgressStoreTests.swift`
- Test: `VoicelyTests/SegmentedAudioTranscriberTests.swift`
- Test: `VoicelyTests/IncrementalTranscriptionCoordinatorTests.swift`
- Test: `VoicelyTests/RecordingSessionTests.swift`

- [x] Write a legacy-sidecar decoding test and a configuration round-trip test.
- [x] Write a segmented-run test that changes the settings provider after the first slice and expects every slice to observe the original configuration.
- [x] Write an incremental coordinator test with the same expectation.
- [x] Run the tests and verify the new expectations fail.
- [x] Add optional `runConfiguration` to the sidecar.
- [x] Capture or resume the configuration once, pass it to every slice, and use it for all chunk/VAD limits.
- [x] Capture a recording configuration once and pass it into the coordinator and final model stamp.
- [x] Run all four focused suites until they pass.

### Task 4: Block engine/model mutation while a run is active

**Files:**
- Modify: `Voicely/TranscriptionService.swift`
- Modify: `Voicely/ContentView.swift`
- Modify: `Voicely/SettingsView.swift`
- Test: `VoicelyTests/TranscriptionServiceTests.swift`
- Test: `VoicelyTests/RecordingSessionTests.swift`

- [x] Write tests that one run owns the engine, a second run is rejected, and unload is refused until the token ends.
- [x] Run the tests and verify they fail.
- [x] Add the single-owner run-token API and published lock state.
- [x] Acquire/release it in segmented and recording paths.
- [x] Disable Settings engine/model/compute mutation and the recording-bar model picker while locked.
- [x] Revert any programmatic AppStorage engine change that races an active run.
- [x] Run the focused tests and a Mac Catalyst build.

### Task 5: Make timing claims honest

**Files:**
- Modify: `Voicely/TranscriptionService.swift`
- Modify: `Voicely/Item.swift`
- Modify: `Voicely/ContentView.swift`
- Test: `VoicelyTests/Qwen3TranscriptionEngineTests.swift`
- Test: `VoicelyTests/VoiceNoteTests.swift`

- [x] Write tests that Qwen results report segment granularity and Qwen notes do not qualify for word-tappable rendering.
- [x] Run the tests and verify the new assertions fail.
- [x] Store granularity on `TranscriptionResult` and derive a note's effective granularity conservatively from its model identifier and timing data.
- [x] Gate `TappableTranscriptView` on word granularity, while keeping the plain transcript as canonical text.
- [x] Run focused tests and build both UI targets.

### Task 6: Preserve genuine repetitions and detect catastrophic loops

**Files:**
- Modify: `Voicely/TranscriptAssembler.swift`
- Modify: `Voicely/TranscriptionService.swift`
- Test: `VoicelyTests/TranscriptAssemblerTests.swift`
- Test: `VoicelyTests/TranscriptionServiceTests.swift`

- [x] Write tests that identical phrases at disjoint times survive and overlapping duplicates are removed.
- [x] Write tests that boundary merging requires overlapping timing ranges.
- [x] Write tests that two or three ordinary repetitions survive while a twelve-cycle suffix loop is rejected.
- [x] Run the tests and verify the current text-only assembler and missing detector fail them.
- [x] Add timestamp overlap/adjacency predicates to assembler decisions.
- [x] Add the conservative repeated-suffix detector and return an explicit decode failure when it triggers.
- [x] Run both focused suites until they pass.

### Task 7: Widen verification

**Files:**
- Verify all changed production and test files.

- [x] Run all Mac Catalyst unit tests.
- [x] Run a Mac Catalyst Debug build.
- [x] Run an iOS Simulator Debug build.
- [x] Run `git diff --check`.
- [x] Review `git status`, diff scope, and the design checklist.

Run:

```bash
xcodebuild -scheme Voicely -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:VoicelyTests test
xcodebuild -scheme Voicely -configuration Debug -destination 'platform=macOS,variant=Mac Catalyst' build
xcodebuild -scheme Voicely -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.0' build
git diff --check
```

Expected: commands exit successfully with no test failures or whitespace errors. Real-device Qwen quality remains a separate release gate.
