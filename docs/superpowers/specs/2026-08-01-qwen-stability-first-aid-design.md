# Qwen Stability First Aid Design

## Goal

Restore trust in the core record, transcribe, read, and play loop without rolling back the correctness fixes added after 0.23.1. Qwen3 remains the preferred engine, while WhisperKit remains an explicit fallback.

## Scope

This first phase is deliberately narrow:

1. Preserve and verify the current Qwen audio-decoding, transient-failure, model-label, and lifecycle fixes.
2. Capture one immutable transcription configuration for each whole run.
3. Persist that configuration in segmented-transcription sidecars so a resumed run cannot silently switch engines, models, language, prompt, chunk size, or timing capability.
4. Prevent engine/model switching, model reloading, and model deletion while a run owns the transcription engine.
5. Treat Qwen timestamps as segment-level data and never present them as word-level synchronization.
6. Preserve genuine repeated speech when identical text occurs at distinct times.
7. Reject only highly conservative catastrophic repetition loops instead of silently rewriting ordinary repetitions.

The phase does not redesign the SwiftData transcript schema, add forced alignment, optimize the audio callback, or rework sidecar performance. Those remain follow-up work after the behavior is stable on real devices.

## Architecture

### Immutable run configuration

`TranscriptionRunConfiguration` is a small Codable value containing the engine, model identifier, language selection, optional prompt, chunk duration, single-pass limit, VAD cut floor, and timing granularity. `TranscriptionService` captures it once at run start and all slice-level calls receive it explicitly.

`SegmentedAudioTranscriber` loads a saved configuration from its sidecar when resuming; otherwise it captures the current settings. `IncrementalTranscriptionCoordinator` receives the recording session's captured configuration in its initializer. No long-running component reads `UserDefaults` to decide the engine or decoding settings after the run begins.

### Engine ownership

`TranscriptionService` owns a lightweight run token. Only one whole run can own the engine at a time. The token exposes a published lock state to Settings and recording controls. Engine unload is refused while a run is active, and user-facing engine/model mutation controls are disabled.

Recording remains the priority. If another transcription already owns the engine, recording still starts and saves audio; it simply skips live incremental transcription and queues the finished note for normal post-recording transcription.

### Timing capability

`TranscriptionTimingGranularity` has `none`, `segment`, and `word` cases. Qwen results are explicitly `segment`; Whisper results are `word`. Segment tokens may still be persisted for resume and internal alignment, but `VoiceNoteDetailView` only renders the word-tappable transcript when the note's effective granularity is `word`.

### Repetition handling

The assembler may remove an identical adjacent piece only when the two timing ranges overlap. Boundary overlap merging also requires overlapping timing ranges, preventing both distant and genuinely back-to-back repeated speech from being collapsed.

A separate conservative detector looks for a repeated suffix motif of at most eight normalized words, repeated at least twelve times and covering at least twenty-four words. Detection turns the decode into an explicit failure/salvage path; it does not silently delete text. Ordinary two- or three-time repetitions are preserved.

## Error handling

- Model or audio unavailability stops a segmented run and preserves its sidecar instead of recursively bisecting the whole file.
- A resumed configuration whose engine is not ready remains queued and does not continue with a different engine.
- A failed run never unloads or changes an engine selected by another active owner.
- Legacy sidecars without a run configuration decode successfully and adopt one configuration on their next resume checkpoint.

## Verification

Automated coverage must include:

- real synthetic WAV and M4A decoding through Qwen's PCM loader;
- transient segmented failures stop without placeholder floods;
- run configuration Codable round-trip and legacy sidecar compatibility;
- changing the settings provider mid-run does not change the configuration observed by later slices;
- active engine ownership blocks unload and model/engine UI mutation paths;
- Qwen segment timing does not enable word-tappable UI;
- repeated phrases at disjoint or back-to-back non-overlapping times are preserved, while overlapping duplicates and boundary overlap are still handled;
- catastrophic repetition detection is conservative;
- focused tests, all Mac Catalyst unit tests, Mac Catalyst build, iOS simulator build, and `git diff --check`.

Passing local tests and builds are not real-device ASR-quality proof. The release gate still requires an iPhone test with real meeting audio, including the observed "Thank you, bye" ending.
