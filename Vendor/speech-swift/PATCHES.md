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

Source files themselves are otherwise byte-identical to the upstream revision.
