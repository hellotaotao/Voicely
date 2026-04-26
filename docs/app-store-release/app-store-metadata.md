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
| Current source version | `0.15.3` build `1`; decide whether the official App Store version should be `1.0` or keep `0.15.3` before archiving |

## Full Description

Voicely is built for meetings where the content matters and discretion matters too. Record long-form discussions, run local transcription on iPhone with WhisperKit and Core ML, and keep a transcript with the original audio for review.

Unlike cloud transcription workflows, Voicely is designed so the speech-to-text step runs on your device after a model is installed. That makes it a practical fit for sensitive internal discussions, client meetings, legal and HR interviews, government contractor work, consulting sessions, and strategy reviews where sending audio to a transcription vendor is not appropriate.

Use Voicely to:

- Capture meeting-length audio from your iPhone.
- Transcribe recordings locally with WhisperKit models.
- Review, edit, copy, and share transcript text.
- Re-transcribe a recording with a different selected model.
- Keep audio and transcripts together for later playback.
- Delete recordings and their audio files when they are no longer needed.
- Choose language, custom prompt, model, and compute settings.
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
- 查看、编辑、复制并分享转写文本。
- 使用不同模型重新转写录音。
- 将音频和文字稿保存在同一条记录中，方便回放。
- 不再需要时删除录音及其音频文件。
- 选择语言、自定义提示词、模型和计算设置。
- 在用户启用并可用的 iCloud 环境中进行同步。

Voicely 不声称具备合规认证，也不能替代组织内部的记录留存、法律审查或合规流程。它是一款本地优先的转写工具：录音和文字稿保存在应用数据中，并可能在 CloudKit 和 iCloud Drive 可用时通过用户的 iCloud 账户同步。模型下载和 iCloud 同步需要网络连接。
