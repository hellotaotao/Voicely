# Bundled WhisperKit models

Place the built-in default WhisperKit model folder here before release builds. The safest packaging shape is a copied bundle folder so Xcode preserves the directory:

```text
Voicely/BundledModels/openai_whisper-small.bundle/
  MelSpectrogram.mlmodelc
  AudioEncoder.mlmodelc
  TextDecoder.mlmodelc
  TextDecoderContextPrefill.mlmodelc
  ...tokenizer files...
```

Voicely also checks `BundledModels/openai_whisper-small/` and the app resource root for compatibility with different Xcode resource-copy behaviors. At runtime Voicely checks bundled locations before using downloaded models or starting a network download. Keep the folder name aligned with `ModelManager.platformDefaultModel`.
