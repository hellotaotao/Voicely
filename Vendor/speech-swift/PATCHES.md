# Local patches vs upstream (soniqo/speech-swift @ 1ad4606418cc98df11197f898a34907e2dd1c4a2)

1. `Sources/AudioCommon/StreamingAudioPlayer.swift`
   - Added `import CoreAudio`.
   - Reason: `UnsafeMutableAudioBufferListPointer` (CoreAudio Swift overlay) is not
     surfaced by `import AVFoundation` when compiling for Mac Catalyst, so the
     upstream file fails to build with
     `cannot find 'UnsafeMutableAudioBufferListPointer' in scope`.
   - Worth upstreaming; the fix is inert on iOS/macOS.

2. `Package.swift`
   - Rewritten to the four targets EverLog consumes (Qwen3ASR, SpeechVAD,
     MLXCommon, AudioCommon) and their two external dependencies
     (mlx-swift, swift-transformers). All TTS/server/CLI/benchmark targets,
     test targets, and the `CSpeechCore` binary artifact are dropped.

3. `Sources/Qwen3ASR/Qwen3ASR.swift`
   - Added `Qwen3DecodingOptions.onToken`, called with each token both
     generation loops emit.
   - Reason: a 29 s slice decodes as one call. iOS expires a background task
     that reports no progress for about 30 s, so the app reports progress per
     token, and it logs whether a slice ended on end-of-turn or the token cap.

4. `Sources/Qwen3ASR/Qwen3ASR.swift`, `Sources/Qwen3ASR/CoreMLTextDecoder.swift`
   - Added `Qwen3DecodingOptions.emitLanguageTag` (default off),
     `Qwen3Transcription` (`parse(_:)`, `readLanguageTag(...)`),
     `Qwen3ASRTokens.asrTextTokenId`, and
     `Qwen3ASRModel.transcription(audio:sampleRate:options:)`;
     `transcribe(...)` and `generateText(...)` now return its `.text`.
     `CoreMLTextDecoder` gained `position` and `rewind(to:)`.
   - With the option on and no language hint, the prompt is prefilled and
     the transcript decoded exactly as before (prompt ending in
     `<|asr_text|>`). Afterwards the model's "language X<asr_text>" tag is
     read greedily from the logits of the position before the marker,
     continuing on the prefill's KV cache minus the marker. Reading the tag
     before the transcript, even on a separate branch, changed a few
     transcript tokens on both MLX and CoreML, so it runs last. On MLX the
     extra work can still tip a near-tie token in a later slice (2 of 136
     slices in the app's paired check, docs/stable-roadmap.md P-0q). With
     the option off, or with a hint, nothing changes. `rewind(to:)` lets
     the app do the same on CoreML, whose cache is stateful.
   - Reason: the app routes pure-English recordings to another engine based
     on the per-slice language the model reports. Letting the model write
     the tag before the transcript changed the text of code-switched audio
     (English written in Chinese after a "Chinese" tag), so the tag is read
     on the side instead.

Source files themselves are otherwise byte-identical to the upstream revision.
