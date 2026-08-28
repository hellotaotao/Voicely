# App Store Metadata

Prepared for the first official App Store release package. Primary copy is English. Chinese copy is optional localization/reference copy.

## Source Grounding

- App target name and bundle: `Voicely.xcodeproj/project.pbxproj:116`, `Voicely.xcodeproj/project.pbxproj:325`
- Current app version/build: `Voicely.xcodeproj/project.pbxproj:301`, `Voicely.xcodeproj/project.pbxproj:324`
- WhisperKit package and version: `Voicely.xcodeproj/project.pbxproj:621`, `Voicely.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved:43`
- Local transcription path: `Voicely/TranscriptionService.swift:631`
- Recording and audio storage path: `Voicely/AudioRecordingService.swift:116`, `Voicely/CloudStorageManager.swift:157`
- iCloud/CloudKit sync support: `Voicely/VoicelyApp.swift:22`, `Voicely/CloudStorageManager.swift:23`, `Voicely/Voicely.entitlements:9`
- Transcript review, editing, copy, share, and retranscribe actions: `Voicely/ContentView.swift:1240`, `Voicely/ContentView.swift:1587`, `Voicely/ContentView.swift:1609`, `Voicely/ContentView.swift:1613`

## App Store Connect Fields

| Field | Proposed value |
| --- | --- |
| App name | Voicely |
| Subtitle | Private Meeting Transcripts |
| Subtitle length | 27 characters, within 30 |
| Promotional text | Record sensitive meetings and create editable transcripts on your iPhone with local WhisperKit transcription and iCloud sync when enabled. |
| Promotional text length | 138 characters, within 170 |
| Short description | Local-first meeting recording and transcription for privacy-conscious professional work. |
| Full description length | 1,660 characters, within 4,000 |
| Keywords | meeting transcription,offline,privacy,WhisperKit,voice recorder,notes,legal,HR,consulting |
| Keywords length | 89 characters, within 100 |
| Primary category suggestion | Productivity |
| Secondary category suggestion | Business |
| Support URL | TODO before submission: use a live public support page, for example `https://hellotaotao.com/voicely/support` |
| Marketing URL | Optional, but recommended: use a live public product page, for example `https://hellotaotao.com/voicely` |
| Privacy Policy URL | TODO before submission: use a live public privacy policy page |
| Copyright | TODO: confirm legal owner name for App Store Connect |
| Current source version | `1.0.0` build `1` (set in `Config/Version.xcconfig`). This is the first **public App Store** release — earlier `0.18.5` was TestFlight-only. Build number must be higher than any build already uploaded under the same `1.0.0` version string. |

## What's New (Release Notes / 1.0.0)

> First public App Store release. Use this in the "What's New in This Version" field. English first, Chinese reference below.

**English**

Voicely's first public release brings on-device meeting transcription to the App Store:

- Tap-to-seek transcript: tap any word to jump audio to that moment, with words highlighting as it plays.
- Live transcript streaming: watch text appear segment by segment, with a collapsible performance card.
- Resilient transcription: failed segments are bisected and retried so one bad stretch no longer loses the whole transcript.
- Per-note language memory and improved automatic language detection.
- Faster first transcription by warming the model on launch, plus decoding stability improvements.

**中文(参考)**

Voicely 首个公开版本,把设备端本地会议转写带到 App Store:

- 点词跳转:点转录里的任意词,音频跳到对应位置,播放时词语同步高亮。
- 实时转录:文字稿边转边一段段出现,并配可折叠的性能指标卡片。
- 更稳的转录:失败片段自动二分重试,单段出错不再拖垮整篇文字稿。
- 逐条记忆所选语言,并改进自动语言检测。
- 启动时预热模型,首次转录更快,解码更稳定。

## Full Description

Voicely is built for meetings where the content matters and discretion matters too. Record long-form discussions, run local transcription on iPhone with WhisperKit and Core ML, and keep a transcript with the original audio for review.

Unlike cloud transcription workflows, Voicely is designed so the speech-to-text step runs on your device after a model is installed. That makes it a practical fit for sensitive internal discussions, client meetings, legal and HR interviews, government contractor work, consulting sessions, and strategy reviews where sending audio to a transcription vendor is not appropriate.

Use Voicely to:

- Capture meeting-length audio from your iPhone.
- Transcribe recordings locally with WhisperKit models.
- Watch the transcript stream in segment by segment as transcription runs, with a collapsible performance card.
- Tap any word in the transcript to jump audio playback to that moment; the words highlight in sync as audio plays.
- Recover partial transcripts automatically — if a segment fails, Voicely bisects and retries so a single bad stretch does not lose the whole recording.
- Review, edit, copy, and share transcript text.
- Re-transcribe a recording with a different selected model.
- Keep audio and transcripts together for later playback.
- Delete recordings and their audio files when they are no longer needed.
- Choose language, custom prompt, model, and compute settings, with per-note language remembered and improved auto-detection.
- Sync through the user's iCloud account when iCloud is available and enabled.

Voicely does not claim compliance certification or replace your organization's records, retention, or legal review process. It is a local-first transcription tool: recordings and transcripts are stored in the app's data store and may sync through the user's iCloud account when CloudKit and iCloud Drive are available. Model downloads and iCloud sync require network connectivity.

Transcription speed and accuracy depend on the selected WhisperKit model, device performance, audio quality, recording length, speaker clarity, and language.

## Age Rating Notes

Suggested age rating questionnaire posture: likely 4+, assuming no built-in objectionable content, gambling, purchases, social networking, or unrestricted in-app web browsing. The app records and transcribes user-created audio, but it does not provide public user-generated content feeds. Settings can open the external WhisperKit model repository in the system browser, not an embedded browser.

Confirm these answers manually in App Store Connect against the final build and any product/legal policy changes.

## Optional Chinese Copy

### App name

Voicely

### Subtitle

私密会议本地转写

### Promotional text

在 iPhone 上录制敏感会议，并使用 WhisperKit 本地转写；可按用户的 iCloud 设置进行同步。

### Short description

面向注重隐私的专业会议录音与本地转写工具。

### Full description

Voicely 面向内容敏感、需要谨慎处理的会议场景。你可以录制长时间讨论，在 iPhone 上通过 WhisperKit 和 Core ML 进行本地转写，并将原始音频与文字稿保存在一起，便于后续回听、整理和复核。

与依赖云端转写服务的流程不同，Voicely 的语音转文字步骤设计为在安装模型后于设备本地运行。它适合内部策略会议、客户访谈、法律与 HR 访谈、政府承包商工作、咨询项目会议，以及其他不希望把会议音频发送给转写供应商的专业场景。

你可以用 Voicely：

- 在 iPhone 上录制会议长度的音频。
- 使用 WhisperKit 模型在本地生成文字稿。
- 转写过程中看文字稿一段段实时流式出现，并配可折叠的性能指标卡片。
- 点击文字稿中的任意词，音频即跳到对应时刻；播放时词语同步高亮。
- 自动救回部分文字稿——某段转写失败时，Voicely 会二分重试，单段出错不会丢掉整段录音。
- 查看、编辑、复制并分享转写文本。
- 使用不同模型重新转写录音。
- 将音频和文字稿保存在同一条记录中，方便回放。
- 不再需要时删除录音及其音频文件。
- 选择语言、自定义提示词、模型和计算设置；逐条记忆所选语言并改进自动检测。
- 在用户启用并可用的 iCloud 环境中进行同步。

Voicely 不声称具备合规认证，也不能替代组织内部的记录留存、法律审查或合规流程。它是一款本地优先的转写工具：录音和文字稿保存在应用数据中，并可能在 CloudKit 和 iCloud Drive 可用时通过用户的 iCloud 账户同步。模型下载和 iCloud 同步需要网络连接。
