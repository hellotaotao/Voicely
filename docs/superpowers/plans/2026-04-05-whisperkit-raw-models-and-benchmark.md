# WhisperKit Raw Models & Compute Benchmark Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two new Settings sub-pages: one showing WhisperKit's unfiltered device-specific model recommendations, and one benchmarking transcription speed across CPU / CPU+GPU / CPU+Neural Engine compute units.

**Architecture:** Two new SwiftUI view files (`WhisperKitModelsView.swift`, `BenchmarkView.swift`) alongside existing views. `SettingsView.swift` gains one `NavigationLink` per feature. No changes to services or data models needed.

**Tech Stack:** SwiftUI, WhisperKit (MIT), CoreML (`MLComputeUnits`, `ModelComputeOptions`), SwiftData (`@Query`), `CloudStorageManager` (existing), `UIKit` (idle timer).

---

## File Map

| Action | File | Responsibility |
|---|---|---|
| Create | `Voicely/WhisperKitModelsView.swift` | Fetch & display raw WhisperKit device recommendations |
| Create | `Voicely/BenchmarkView.swift` | Select audio, run 3-round benchmark, show results |
| Modify | `Voicely/SettingsView.swift` | Two `NavigationLink` entries |

---

## Task 1: WhisperKitModelsView

- [ ] Create `Voicely/WhisperKitModelsView.swift`
- [ ] Build succeeds
- [ ] Commit

## Task 2: Wire WhisperKitModelsView into SettingsView

- [ ] Add NavigationLink in Model Management section of SettingsView
- [ ] Build succeeds
- [ ] Commit

## Task 3: BenchmarkView

- [ ] Create `Voicely/BenchmarkView.swift`
- [ ] Build succeeds
- [ ] Commit

## Task 4: Wire BenchmarkView into SettingsView

- [ ] Add NavigationLink in Compute Settings section of SettingsView
- [ ] Build succeeds
- [ ] Final commit
