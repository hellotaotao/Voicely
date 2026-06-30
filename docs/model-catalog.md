# Speech Model Catalog

What each on-device transcription option in the app maps to, and **why** — so the
rationale (and the traps we hit) aren't lost.

**Source of truth is `ModelManager.curatedModels` in `Voicely/ModelManager.swift`.**
This doc explains it; the code defines it.

- WhisperKit version: **0.16.0**
- Models pulled from HuggingFace repo `argmaxinc/whisperkit-coreml`

## Current options (Settings picker)

| UI label | Tier | WhisperKit identifier | Download size | What it is |
|---|---|---|---|---|
| Lite (Base) | Lite | `openai_whisper-base` | 147 MB | Multilingual base |
| Standard (Small) | Standard | `openai_whisper-small` | 486 MB | Multilingual small, full precision |
| Pro (Large v3 Turbo) | Pro | `openai_whisper-large-v3-v20240930_626MB` | 626 MB | OpenAI's official 2024-09-30 large-v3-**turbo**, quantized |
| Pro Fast (Large v3 Turbo) | Pro Fast | `openai_whisper-large-v3-v20240930_turbo_632MB` | 646 MB | **Same** v20240930 turbo as Pro — identical 203 MB TextDecoder, ~7 MB larger encoder. Separate option per product decision; **not actually faster** than Pro. |
| Standard (Small, English) | Standard | `openai_whisper-small.en_217MB` | 218 MB | English-only small, quantized |

Picker order: Lite → Standard → Pro → Pro Fast, English-only variant last.

## Why these, and the gotchas

- **"Turbo" = distilled decoder.** Decoder pruned 32 → 4 layers (encoder stays 32),
  ~809M params, ~99% of large-v3 accuracy, 4–8× faster. The tell-tale sign of a turbo
  build is **TextDecoder ≪ AudioEncoder** in the model folder.
- **The whole `large-v3-v20240930` family IS turbo.** OpenAI released large-v3-turbo on
  2024-09-30; argmax names that checkpoint by date. The `_turbo` suffix on some variants
  is redundant — `large-v3-v20240930_626MB` and `large-v3-v20240930_turbo_632MB` share the
  exact same 203 MB TextDecoder. (decoder/encoder ratio ≈ 0.47–0.48 → turbo.)
- **Avoid the no-date `large-v3_turbo`.** It's argmax's older (2023-based) build; its
  TextDecoder is a full 1815 MB, so the folder is **3.2 GB**, not the ~1 GB you'd guess.
  Its quantized sibling `large-v3_turbo_954MB` (what Pro used to point at) is that old
  checkpoint at ~1.05 GB. Pro now uses the newer, smaller, official `v20240930_626MB`.
- **`small.en_217MB` is real but NOT in `recommendedRemoteModels()`.** WhisperKit
  recommends `small.en` (486 MB); the 218 MB quantized variant exists on HF but isn't in
  the supported list. So `fetchModels` must NOT gate visibility on the supported list — it
  surfaces the full curated catalog minus whatever WhisperKit explicitly marks disabled.

## Device defaults

`ModelManager.platformDefaultModel`: Mac and A16+ iPhones (iPhone 15 and up) default to
**Pro**; everything else defaults to **Standard**. Lite is always selectable but never an
automatic default.

## How to verify sizes / turbo-ness / availability (don't guess — measure)

- **Folder size** (≈ download size): HuggingFace tree API, sum the file sizes:
  `https://huggingface.co/api/models/argmaxinc/whisperkit-coreml/tree/main/<identifier>?recursive=true`
- **Turbo or not**: in that listing, compare `TextDecoder.mlmodelc` vs
  `AudioEncoder.mlmodelc` totals — decoder ≪ encoder means turbo.
- **What this device can actually run**: call `WhisperKit.recommendedRemoteModels()` and
  inspect `.supported` / `.disabled`. These use WhisperKit's own variant names, which can
  differ from the HF folder names — that mismatch is the `small.en` trap above.
