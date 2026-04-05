# Design: WhisperKit Raw Model List & Compute Benchmark

**Date:** 2026-04-04  
**Status:** Approved

---

## Context

Voicely currently filters and overrides WhisperKit's device-specific model recommendations in `ModelManager.loadAvailableModels()`. Users have no visibility into what WhisperKit natively recommends for their device. Additionally, users cannot easily determine which compute unit (CPU / CPU+GPU / CPU+Neural Engine) is fastest on their specific hardware. Two new Settings pages address both gaps.

---

## Feature 1: WhisperKit Raw Recommended Models Page

### Goal
Show users the unfiltered, device-specific model list that WhisperKit returns, purely for informational purposes.

### New File
`Voicely/WhisperKitModelsView.swift`

### Behavior
- On appear: call `WhisperKit.recommendedModels()` and `WhisperKit.recommendedRemoteModels()` directly (not through ModelManager)
- Display two sections:
  - **Supported** — models in `remoteModels.supported`, with the `recommendedModels().default` marked with a badge (e.g., "Device Default")
  - **Disabled for this device** — models in `remoteModels.disabled`, shown in gray
- Read-only: no ability to load a model from this view
- Shows a loading spinner while fetching; shows an error message if fetch fails

### SettingsView Entry Point
In the "Model Management" section of `SettingsView`, add a `NavigationLink` row below the existing model selector:
```
"WhisperKit Device Recommendations"  →  WhisperKitModelsView
```

---

## Feature 2: Compute Unit Benchmark Page

### Goal
Let users run a timed transcription with all three compute unit configurations and compare results side-by-side.

### New File
`Voicely/BenchmarkView.swift`

### Entry Point
In the "Compute Settings" section of `SettingsView`, add a `NavigationLink`:
```
"Run Benchmark"  →  BenchmarkView
```

### Flow

#### Step 1 — Select Audio
- List existing `VoiceNote` items that have a local audio file
- User taps one to select it; selection is highlighted
- "Start Benchmark" button becomes active once a note is selected

#### Step 2 — Running
- Tests run sequentially: CPU → CPU+GPU → CPU+Neural Engine
- Each round:
  1. Create a temporary `WhisperKit` instance pointing to the already-downloaded local model folder (no re-download)
  2. Record wall-clock start time
  3. Call `whisperKit.transcribe(audioPath:decodeOptions:)` with default decode options
  4. Record elapsed time and capture first ~100 chars of transcript
  5. Destroy the temporary instance
- UI shows current round name and a `ProgressView`
- `UIApplication.shared.isIdleTimerDisabled = true` for the duration; reset on completion or cancellation

#### Step 3 — Results
Display a table with one row per compute unit:

| Compute Unit | Time (s) | RTF | Transcript Preview |
|---|---|---|---|
| CPU | 12.3 | 0.82× | "今天天气..." |
| CPU + GPU | 8.1 | 0.54× | "今天天气..." |
| CPU + ANE | 5.2 | 0.35× | "今天天气..." |

- **RTF** = elapsed / audio duration (lower is better)
- Fastest row highlighted in green
- "Apply Fastest" button: sets `ModelManager.encoderComputeUnits` and `ModelManager.decoderComputeUnits` to the winning configuration and pops back to Settings

### Prerequisites / Error Handling
- Before allowing "Start", check that `ModelManager.shared.isModelLoaded()` returns true; show inline warning if not
- If a single round fails (e.g., memory pressure), mark that row as "Failed" and continue to next round
- Cancel button available during run; cancelling mid-round kills the temporary WhisperKit instance

### Non-Goals
- Does not benchmark different Whisper model sizes (only tests the currently loaded model)
- Does not persist benchmark results across sessions

---

## Files to Modify / Create

| Action | File |
|---|---|
| Create | `Voicely/WhisperKitModelsView.swift` |
| Create | `Voicely/BenchmarkView.swift` |
| Modify | `Voicely/SettingsView.swift` — add two `NavigationLink` entries |

---

## Verification

1. **WhisperKit Models View**
   - Open Settings → tap "WhisperKit Device Recommendations"
   - Verify list loads without error; confirm "Device Default" badge appears on one model
   - Confirm disabled models appear grayed out
   - Confirm no load/download action is possible from this view

2. **Benchmark View**
   - Open Settings → tap "Run Benchmark"
   - Confirm "Start" is disabled until a note is selected
   - Confirm "Start" is disabled (with warning) if no model is loaded
   - Select a note, tap Start; verify all three rounds run and results appear
   - Verify RTF calculation is correct (elapsed / audio duration)
   - Tap "Apply Fastest"; verify compute unit setting updates in Settings and model reloads with new units
   - Verify screen does not auto-lock during benchmark
