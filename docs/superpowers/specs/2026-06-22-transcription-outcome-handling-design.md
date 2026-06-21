# 转录「无结果」处理重构 · 设计

- 日期:2026-06-22
- 状态:待评审
- 触发:录音详情页对一条 14s 录音显示红色「Transcription needs review」,用户既无法 review 也无从解决,只增恐慌。

## 背景与问题

当前所有「没拿到文字」的情况都坍缩成一个 `nil`(`transcribeAudio` 返回 `nil`),统一打上红色 `PillBadge("Transcription needs review")` + 文案「The last attempt did not produce a usable transcript. You can retry or choose a different model.」。问题有四:

1. **把内部技术判定用最吓人的视觉甩给用户**:红三角 + "needs review" 暗示用户去复核,但根本没有可复核的东西;用户无法 review、无法解决,只增 panic。
2. **6 种性质完全不同的原因被糊成同一句话**(见下表)。
3. **自作主张「翻译」Whisper 的非语音判断**:`LocalTranscriptFinalizer.swift:62-69` 把 Whisper 明确吐出的 `Music` / `Laughter` / `Applause` 等标记一律抹成笼统的 `[BLANK_AUDIO]`。
4. **真出错时两头落空**:异常分支(`TranscriptionService.swift:921-924`)只 `print` 一行就吞掉,空结果(`:916`)与纯空白(finalize 返回 nil)连日志都没有 —— 开发者无从排查;给用户的红警告也毫无帮助。

## 设计原则

- **如实呈现,零加工(最高优先)**:Whisper / 系统给什么,就给用户什么 —— 不翻译、不归类、不编官腔。屏幕上只允许两处出现「我们写的话」:① VAD 全程无语音(没有任何输出)时,补一句最朴素的 "No speech",免得全白让用户发懵;② 真出错(Whisper 自己挂了、没有任何内容可呈现)时,一句诚实的「这次没成功,可重试」。除此之外一律原文。
- **能我们自己扛的自己扛**,只在中性、无害时给用户一句平静说明。
- **彻底删除红色 "Transcription needs review"**,一种来源都不保留。
- **真实技术报错只进日志、供开发者排查**,绝不甩上屏幕吓人,也绝不假装成功。

## 核心:6 个来源 → 新行为

`transcribeAudio` 返回 `nil` 现有 6 个来源,按真实性质分流:

| # | 来源 | 代码位置 | 新行为 | 用户看到 |
|---|---|---|---|---|
| 1 | VAD 预检判无语音 | `TranscriptionService.swift:820` | 完成,标记「确认无语音」 | 平静中性卡:No speech detected |
| 2 | 模型不可用 | `:788` | **不算失败**,保持 pending;监听 `modelLoadedNotification`,加载完自动重转 | 平静卡:等模型就绪会自动开始 + Download 入口 |
| 3 | 音频文件未就绪 | `:801` | **不碰**,维持跨设备手动认领(非本机录音不自动抢) | 现状(等待/手动) |
| 4 | WhisperKit 空结果 | `:916` | 真问题:自动重试 1 次;仍失败 → failed + 诊断 | 低调卡:这次没转成功,可重试 |
| 5 | WhisperKit 抛异常 | `:921` | 同上 | 同上 |
| 6 | 吐出纯空白(finalize nil) | `LocalTranscriptFinalizer.swift:62-63` | 同上 | 同上 |

> 说明:走到 4/5/6 的录音都已通过 VAD 预检(VAD 在 Whisper 之前,不过直接 return)。即「VAD 说有语音,但 Whisper 没转出来」,属反常,归为真问题、需排查 —— 而非伪装成空白。

另外,**非语音标记**(Whisper 整段吐 `Music`/`Laughter` 等,经 sanitizer 后只剩这些)不再走 `[BLANK_AUDIO]`,改为如实保留 Whisper 原文。

> 「无语音」只在**整段从头到尾无语音**时才提示。录音中间夹几秒/十几秒没人说话,直接跳过、屏幕上什么都不加(前后语音照常接上)—— 这是混合内容的正常过滤,维持现状。

## 关键改动

### 1. 如实保留非语音标记(去掉 `[BLANK_AUDIO]` 翻译)
- `LocalTranscriptFinalizer.finalizeTranscript`(`:62-69`):当过滤后整段为空且 `removedLineCount > 0`(即整段都是非语音标记),**不再返回 `blankAudioTranscript`**,改为返回被过滤行的 **Whisper 原文**(去重后)。Whisper 说 Music 就 Music,说 Laughter 就 Laughter。
- **混合内容维持现状**:一段话中间夹 `[Music]` 时,仍过滤掉非语音标记、只留语音。只有「整段都是非语音」时才保留原话。
- `blankAudioTranscript` 常量及其在 `VoiceNoteAutoTitle` / `IncrementalTranscriptionCoordinator` 的引用相应调整(自动标题、实时增量仍需跳过这些非语音占位)。

### 2. 把「返回 nil」升级为带原因的结果
- 引入 `enum TranscriptionOutcome`:`transcribed(text) / noSpeech / modelUnavailable / audioUnavailable / whisperError(Error?) / cancelled`。
- 6 个源头各自返回对应 case,替代裸 `nil`。

### 3. 分类处理(`transcribeClaimedNote`)
- `transcribed`(含非语音标记原文)→ `completeTranscription()`,显示文本。
- `noSpeech` → 完成 + 设 outcome = noSpeech(中性,非错误)。
- `modelUnavailable` → 不设失败、不清 pending;挂 `modelLoadedNotification`,模型就绪后自动重新入队转录。
- `audioUnavailable` → 维持现状(手动认领),不自动重试。
- `whisperError` → 本次 attempt 内自动重试 1 次;仍失败 → 设 outcome = failed + 写诊断。
- `cancelled` → `requeueNote`(现状)。

### 4. 如何区分这几种结局(实现细节,评审可略)
UI 要分辨「正常文本 / 整段无语音 / 真出错 / 还没转」,需要一个结局标记;具体字段名实现时定,原则不变:
- 真实技术报错(Whisper 的 exception、空结果等)**只写日志、供我们排查**,不往屏幕甩,也不假装成功。
- 屏幕上的文字只有两个来源:**Whisper 原文**,或设计原则里那两处「我们写的话」。

### 5. UI(详情页 transcription card,`ContentView.swift` ~2128–2261;列表/紧凑视图同源逻辑 ~720–790)
- **删除**红色 `"Transcription needs review"` 分支(`:2240-2253`)及对应紧凑视图分支。
- 新增按 outcome 渲染:
  - `noSpeech` → 中性灰卡,图标用 `waveform.slash`(非 `exclamationmark.triangle`),variant `.neutral`/`.info`。
  - 模型未就绪(pending 且模型不可用)→ 平静卡 + "Download a model" 入口(跳模型界面)。
  - `failed` → 低调卡(非红、非 danger)+ "Try again"。
  - `transcribed` → 显示 `note.transcription`(含非语音标记原文)。

### 6. 诊断
- 异常分支(`:921`)、空结果(`:916`)、纯空白三条都补 `#if DEBUG` 日志,写明真实原因。
- 真实原因落到 `transcriptionLastErrorMessage`(内部用),供排查 #1 那条 14s 录音之类的问题。

## 文案(只有两处是「我们写的话」,其余全是 Whisper 原文)

- VAD 全程无语音:**No speech**(朴素一句即可,不堆形容词)。
- 真出错:**Couldn't transcribe — tap to try again**(诚实、低调,非红)。
- 等模型(暂态,非失败):**Waiting for a model** + Download 入口。
- 非语音标记 / 正常语音:**Whisper 原文**,不另造文案。

## 不做(YAGNI)

- 不做 prompt 回声检测(代码本就没有,且非本问题成因)。
- 不改混合内容的非语音过滤逻辑。
- 不碰跨设备认领机制(维持手动 transcribe/take over)。
- 真出错默认**不**伪装成空白音频(会掩盖 bug)。

## 测试

- 改:`nonSpeechOnlyTranscriptionCompletesAsBlankAudio` —— 不再期望 `[BLANK_AUDIO]`,改为期望保留 Whisper 原文。
- 改:`emptyTranscriptionResultStopsQueueAndClearsMetadata` —— 对齐新的 whisperError → 重试 → failed 路径。
- 新增:
  - VAD 无语音 → outcome = noSpeech,不设 error message,不报警。
  - whisperError → 自动重试 1 次;仍失败 → outcome = failed + 诊断写入。
  - modelUnavailable → 保持 pending、不报失败;`modelLoadedNotification` 后自动重转。
  - 整段非语音标记(Music/Laughter)→ 如实保留,不被抹成 `[BLANK_AUDIO]`。
  - 混合内容 → 非语音标记仍被过滤、语音保留。

## 开放问题

- `noSpeech`(VAD 拦下,无 Whisper 输出)与「整段非语音标记」(有 Whisper 原文如 Music)在 UI 上是否要统一视觉、还是分别呈现。倾向:都用同一种中性卡,前者文案 "No speech detected",后者直接显示原文。
