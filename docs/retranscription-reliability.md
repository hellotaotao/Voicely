# Retranscription reliability repair

Scope: the 0.23.3 development tree. No transcription engine, release version,
or cloud storage policy changes. Archiving and TestFlight upload are outside this repair.

## Behavior contracts

- Keep the saved transcript visible during queueing, active decoding, partial
  preview, cancellation, and failure. Only a successful complete retry replaces it.
- User cancellation persists as `transcriptionStateRaw = "cancelled"` using the
  existing string field. Clear queue/owner/attempt/lease flags and save immediately.
  Automatic recovery cannot requeue or claim this state. An explicit retry can.
- Cancel queued jobs independently. A cancelled active decoder retains its engine
  slot until it exits, after which other queued notes continue. Late results never
  replace the saved transcript. Recheck cancellation after metadata awaits before
  launching a decoder.
- Preserve import working copies and recording checkpoints after cancellation.
  Temporary model/audio/background interruptions remain resumable queue states.
- Treat nonpositive and nonfinite duration metadata as unknown. Show an unknown
  duration label rather than a zero-length recording. Decorative waveform rendering
  is restored to HEAD, including its existing real-level and seeded fallback paths.
- Local recording ownership spans recording and final flush. These notes cannot be
  cancelled through saved-note transcription actions or shown as queued when their
  five-minute lease expires. After ownership ends, normal queue/cancel rules apply.
- Resolve real duration when selected audio becomes readable and after player
  preparation; write it back to the matching note. Selection-generation checks
  prevent stale asynchronous reads from updating a newly selected note.
- Resolve the actual source file and read its duration before choosing single-pass
  versus segmented transcription. Stale or zero note metadata cannot send long
  audio through the single-pass path. An unreadable duration preserves prior text
  and reports failure rather than guessing the route.

## Changed areas

- `Voicely/Item.swift`: persisted cancellation state and duration validity helpers.
- `Voicely/TranscriptionService.swift`: queue cancellation, explicit resume,
  cancellation races, source-based routing, and recording/final-flush boundaries.
- `Voicely/SegmentedAudioTranscriber.swift`: durable cancellation guards and metadata.
- `Voicely/AudioPlayerService.swift`: duration resolution and selection-safe callback.
- `Voicely/ContentView.swift`: independent saved text/status/preview, cancel/resume UI,
  unknown duration, metadata persistence.
- `Voicely/VoicelyApp.swift`: UI fixture supports saved text with a queued retry.
- `Voicely/AudioRecordingService.swift`: disable implicit microphone prewarming only
  during automated tests; simulator audio RPC timeout was aborting test launches.
- Unit regressions in `TranscriptionServiceTests`, `SegmentedAudioTranscriberTests`,
  `CloudStorageManagerTests`, and `VoiceNoteModelTests`; recording recovery fixture
  updated for the resolved-file boundary. New lifecycle regressions exercise the
  real recording coordinator with a gated stub decoder through successful final
  flush and failed-tail recovery. UI regressions in `VoicelyUITests`; the expired
  live-recording UI fixture does not open the microphone.

## Validation

The initial regression run failed with the expected cancellation/persistence and
long-audio routing assertions (69 tests, 14 issues). A later focused regression
also proved cancellation during telemetry preparation could still start decoding.

## P1 correction after Opus discussion

The prior 238-test suite missed a regression in the uncommitted repair: a local
recording's lease expired after 300 seconds, the UI offered queue actions, and
cancellation persisted a state that blocked failed-tail whole-file recovery.

The correction adds only two service guards: reject saved-note cancellation while
local recording ownership exists, and exclude the same notes from pending status.
Existing ownership already spans final flush, so no new state, lease heartbeat,
UI status chain, or defensive auto-resume rule was added. The cancelled queue guard
remains intact. Decoder settings, VAD thresholds and whole-file recovery policy
are unchanged. The decorative waveform placeholder change is withdrawn.

Opus reviewed the proposed boundary against source. Its suggestion to delete the
waveform extractor/cache was rejected after checking HEAD: both are existing
features still used by the restored view. The third discussion could not read its
previous report outside its restricted directory; it re-derived the recording
path from source. The final code has primary automated validation, not a further
independent Opus review. Raw reports and primary dispositions are outside the repo
under `/tmp/voicely-opus-review-20260909-094157/`.

Red regression evidence:
- Service/lifecycle run: 61 tests, 20 expected issues after correcting the fixture
  to request a frame beyond the full-batch boundary. Failures demonstrate expired
  live-state misclassification, cancellation mutation, and blocked tail recovery.
- Simulator: all three new/adjusted UI checks fail on the old code (two live-state
  cases, one withdrawn waveform-placeholder expectation).
- Logs: `/tmp/voicely-p1-fix-20260909/red-mac-corrected-fixture.log` and `red-ui.log`.

## Final automated validation

Status: PASS for the final source tree; real-device release acceptance is pending.

- Focused Mac regression: 61 tests passed, including both final-flush outcomes.
- Full Mac Catalyst suite: 241 unit tests in 30 suites passed.
- iPhone 17 / iOS 26.5 simulator: 241 unit tests and 21 UI executions passed.
- Unsigned iOS Release build and `git diff --check`: passed.
- Source hashes were unchanged throughout the full validation run.
- Final logs are `/tmp/voicely-p1-fix-20260909/final-mac.log`, `final-ios.log`,
  and `final-release.log`.
- Exported screenshots were visually checked: the expired-lease fixture shows
  Live transcript without queue/cancel actions, and unknown total duration stays
  unknown with the original decorative waveform. Copies are under
  `build/reliability-fix-validation/p1-correction/`.

Commands run from the repository root:

```sh
xcodebuild -scheme Voicely -destination 'platform=macOS,variant=Mac Catalyst' \
  -parallel-testing-enabled NO -enableCodeCoverage NO \
  -disableAutomaticPackageResolution -skipPackageUpdates -only-testing:VoicelyTests test
xcodebuild -scheme Voicely -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -parallel-testing-enabled NO -enableCodeCoverage NO \
  -disableAutomaticPackageResolution -skipPackageUpdates test
xcodebuild -scheme Voicely -configuration Release -destination 'generic/platform=iOS' \
  -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO build
git diff --check
```

The repair baseline remains 0.23.3 (3). Version changes, push, archive, and upload
are separate from this repair.

## Device gate

The original 26-minute Chinese recording, real WhisperKit throughput, actual
force-quit/relaunch on iPhone, and real iCloud synchronization/download behavior
still require device validation. Routing tests use real CAF files with a stubbed
ASR result, not the user's recording. Persistence is tested by reopening an on-disk
SwiftData store with a fresh service. Prior 0.23.3 cancellations were not recorded
persistently; cancel such a queued job once in the repaired build to record intent.
