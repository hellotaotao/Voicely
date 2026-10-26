# App Store Metadata

Prepared for Voicely's first public App Store release; it has only shipped through TestFlight so far, so this is a new listing, not an update. Primary copy is English; the Chinese copy is a localization.

## Source Grounding

- Speech engine: Qwen3-ASR 0.6B, bundled in the app (`Voicely/Qwen3TranscriptionEngine.swift`, `scripts/embed-speech-model.sh`). The Mac app runs it with MLX on the GPU; iPhone and iPad run it with Core ML on the CPU and Neural Engine. Nothing is downloaded at runtime.
- Supported languages: the 30 in `Qwen3ASRDefaults.languageNames`, plus auto-detect, which also handles Chinese mixed with English.
- Recording: `Voicely/AudioRecordingService.swift`; transcription while recording and after stop: `Voicely/RecordingSession.swift`, `Voicely/TranscriptionService.swift`.
- iCloud: SwiftData with CloudKit for notes, iCloud Documents for audio (`Voicely/VoicelyApp.swift`, `Voicely/CloudStorageManager.swift`).
- Audio import: `CFBundleDocumentTypes` in `Voicely/Info.plist` (m4a, mp3, wav, aiff).
- System entry points: Live Activity (`VoicelyWidgets/`), App Intents (`StartRecordingIntent.swift`, `ToggleRecordingPauseIntent.swift`), Home Screen quick action.
- Version: `Config/Version.xcconfig` (currently `0.28.0` build `1`).

## App Store Connect Fields

| Field | Proposed value |
| --- | --- |
| App name | Voicely |
| Subtitle | Private Meeting Transcripts (27 of 30 characters) |
| Promotional text | Record meetings and get a full transcript on your iPhone, iPad or Mac. Speech recognition runs on the device; nothing is uploaded for transcription. (148 of 170) |
| Keywords | meeting,transcription,transcribe,recorder,offline,private,speech to text,minutes,interview,notes (96 of 100) |
| Primary category | Productivity |
| Secondary category | Business |
| Platforms | iPhone and iPad (iOS/iPadOS 18 or later); Mac with Apple silicon (macOS 15 or later, Mac Catalyst build). Intel Macs are not supported. |
| App size | About 1.1 GB per platform, almost all of it the speech model. Over the cellular download limit, so first install usually needs Wi-Fi or the user's permission. |
| Support URL | TODO before submission: a live public page, e.g. `https://hellotaotao.com/voicely/support` |
| Marketing URL | Optional: e.g. `https://hellotaotao.com/voicely` |
| Privacy Policy URL | TODO before submission: a live public page; draft in `privacy-and-review-notes.md` |
| Copyright | TODO: confirm the legal owner name |
| Version | Decide whether the first public version is `1.0` or continues from `0.28.x`, then set it in `Config/Version.xcconfig` |

## Full Description

Voicely records your meetings and turns them into a full transcript, on your own device. The speech model ships inside the app, so recognition works offline and your audio is never uploaded for transcription.

Start recording and the transcript builds while the meeting runs. When you stop, Voicely finishes the last few seconds and the text is ready to read, copy, or paste into the AI assistant you use for summaries and action items.

- Record meetings of any length on iPhone, iPad, or Mac.
- Transcripts appear while you record and finish shortly after you stop.
- Transcription keeps running after you lock your iPhone or switch apps.
- Tap a sentence to hear it; the transcript follows along during playback.
- Mixed-language meetings work: auto-detect handles Chinese with English. Choose from 30 languages if you need to.
- Set a recording to stop at a time or after a duration, with a reminder before it stops and one-tap extensions.
- Import audio files from Files or other apps and transcribe them.
- Copy, share, edit, or re-transcribe any note.
- Pause or resume from the Lock Screen and Dynamic Island; start recording from Shortcuts or the Home Screen icon.
- Sync notes and audio across your devices with your own iCloud account, if you turn on iCloud for Voicely.

Voicely has no account, no ads, and no analytics. Recordings and transcripts stay on your devices and in your iCloud account; the developer cannot see them.

Voicely does not claim any compliance certification and does not replace your organization's recording-consent, retention, or legal review policies. Accuracy depends on audio quality, distance from the speakers, crosstalk, and language.

## Age Rating Notes

Likely 4+: no objectionable content, gambling, purchases, social features, or web browsing. The app records and transcribes the user's own audio and has no public user-generated content. Confirm the questionnaire against the final build.

## Chinese Localization

### Subtitle

私密会议转写（本机识别）

### Promotional text

在 iPhone、iPad 或 Mac 上录下会议，得到完整文字稿。语音识别在设备上完成，不上传任何音频做转写。

### Keywords

会议,转写,录音,语音转文字,会议记录,离线,隐私,访谈,纪要,笔记

### Full description

Voicely 录下你的会议，并在你自己的设备上把它变成完整的文字稿。语音模型随 App 一起安装，识别不需要联网，音频不会为了转写而上传。

开始录音后，文字稿随会议进行逐段生成。停止录音后，Voicely 把最后几秒转完，文字稿就可以阅读、复制，或者粘贴给你常用的 AI 助手去做总结和待办整理。

- 在 iPhone、iPad 或 Mac 上录制任意长度的会议。
- 录音时边录边转，停止后很快完成。
- 锁屏或切到其他 App 后，转写继续进行。
- 点一句文字即可从这句开始回放，播放时文字稿自动跟随。
- 支持中英混说：自动识别能处理中文里夹英文；需要时也可以从 30 种语言中手动指定。
- 可以设定到点或按时长自动停止录音，停止前有提醒，可一键延长。
- 从"文件"或其他 App 导入音频并转写。
- 复制、分享、编辑文字稿，或重新转写。
- 在锁屏和灵动岛上暂停或继续录音；从快捷指令或主屏幕图标直接开始录音。
- 打开 iCloud 后，笔记和音频通过你自己的 iCloud 账户在设备间同步。

Voicely 不需要注册账户，没有广告，也不做任何统计分析。录音和文字稿只保存在你的设备和你的 iCloud 账户里，开发者无法看到。

Voicely 不声称具备任何合规认证，也不能替代你所在组织关于录音告知、记录留存或法律审查的规定。转写准确度取决于音质、与说话人的距离、多人同时说话的情况以及语言。
