# TODO

## ⬜ 待办(提出 2026-06-23) — 利用 timestamp:音频 ↔ 文字双向定位

> transcribe 时本来就带 timestamp,别浪费掉。

理想效果(类似卡拉 OK 跟读):

- **拖动录音 → 文字跟着走**:拖动 / scrub 录音进度时,transcription 自动滚动到对应位置,并高亮当前时间点正在说的那个词。
- **长按词 → 录音跳过去**:在 transcription 里长按某个词,录音自动跳到说那个词时的位置(播放定位)。

即用每个词 / 每段的时间戳把「播放进度」和「文字位置」绑成双向同步。

---

## 🟡 进行中(提出 2026-06-23) — Re-transcribe / 整文件转录:三个问题

> 用户观察,根因待核实,先记录不脑补。

### 1. ✅ 已不复现 — time ratio 与 speed 一直停在 "measuring"
做 re-transcribe 时,benchmark 的 time ratio 和 speed 好像**永远显示 "measuring"**,出不来值。
**2026-06-27 用户反馈:此问题已不复现,不再是问题。** 不改。

### 2. ✅ 已修复(2026-06-27) — 分段转录应当一段一段出内容,而非等整文件转完才显示
re-transcribe、或拖入一个文件整体转录时,过去要等**整个文件完全转完**才显示文字。
**修复:**
- `SegmentedAudioTranscriber.transcribeSegmented`:循环里每段完成后即 `note.transcription = pieces.joined(...)`(仅在已产出真实文本后,避免 re-transcribe 失败时丢掉旧文本)。
- `ContentView.transcriptionBody` 的 `isLocallyTranscribing` 分支:进度条下方增量显示 `note.transcription`(此前该分支只画进度条、完全不渲染文字)。
- 回归测试 `segmentedRunUpdatesTranscriptIncrementally`。

### 3. ✅ 已修复(2026-06-27) — 转录完成后 benchmark 指标整块消失
**方案(已实现):把 performance 指标那一块做成可折叠(collapsible)。**
- 转录**进行中**:自动**展开**,实时看指标。
- 转录**完成**:自动**折叠**收起,指标仍在(点 header 展开)。
- 用户手动点开/收起会覆盖自动规则;下次转录开始/结束时(`onChange(isTranscribingHere)`)重置回自动。

**配套修复:** 分段 / 单遍导入路径过去**从不持久化** telemetry(`transcribeClaimedNote` 在分段分支提前 return),完成后无指标可显示。现新增 `TranscriptionService.finishedTelemetrySnapshot`,在 `SegmentedAudioTranscriber` 完成时按"各段处理时间之和 ÷ 音频总时长"持久化整体指标;完成态 card 改用 note 上持久化的 `averageProcessingTimeRatioLabel` / `averageTranscriptionSpeedLabel` 等(live timer 此时已 reset)。

---

## ⬜ 待办(提出 2026-06-22) — iCloud 同步:文字内容优先,音频延后下载

### 现象 / 诉求
打开 app 后,尤其积压多天未同步时,要等很久列表才一致,怀疑被中间的大音频文件拖住。诉求:**先把 notes + 转录文字同步进来让列表先一致**(用户即可确认"东西都在"),音频文件慢慢按需下载即可。

### 现状(架构)
- notes + 转录文字:SwiftData + CloudKit `.automatic`(`VoicelyApp.swift:54-71`),这是列表出现的通道。
- 音频文件:iCloud Documents,**已是按需下载**——`prepareFileForReading`(`CloudStorageManager.swift:459`)仅在播放/转录/benchmark 时拉取(`AudioPlayerService`、`TranscriptionService.swift:879`、`BenchmarkView.swift:289`);全量 `forceDownloadAll`(`CloudStorageManager.swift:686`)只在 `SyncStatusView.swift:42` 用户主动点击时触发。
- 即两通道本就独立,音频不会自动全量下载;但用户体感列表仍迟迟不一致。参见记忆 [[icloud-sync-transcription]]。

### 待调查 / 方向
- 定位"列表迟迟不一致"的真实瓶颈:是 CloudKit 初次拉取 note 记录本身慢(可能正常),还是 UI/某处在等音频元数据或文件就绪才渲染?
- 确认 note 行渲染**完全不依赖**本地音频存在(无音频应有占位,不阻塞列表)。
- 同步状态 UI 区分"文字已同步 / 音频待下载",让用户先确信列表完整。
- 排除任何启动即批量 `startDownloadingUbiquitousItem` 间接抢占带宽、拖慢 CloudKit 的路径。

---

## ✅ 已完成(2026-06-22) — Settings Benchmark 三个问题

### 1. 入口整行点击热区(空白处点不动)✅
`navRow`(`SettingsView.swift:531-544`)的 HStack 加 `.contentShape(Rectangle())`,Spacer 空白区现在也可点。

### 2. "Start Benchmark" 视觉不居中(实为 icon 与按钮底色同色而隐形)✅
真凶:`SettingsView.swift:215` 给整个 Settings NavigationStack 设了 `.tint(VoicelyTheme.accent)`,BenchmarkView 继承后,`.borderedProminent` 按钮(背景=tint=accent)里的 `timer` 图标在 Mac Catalyst 上也被染成 accent 色 → 与背景同色隐形(文字被系统反白故仍可见),视觉上偏右。改:去掉 `systemImage` 改纯 `Text("Start Benchmark")`,文字真正居中(`BenchmarkView.swift:194-201`)。Cancel/Apply 是 `.bordered` 非 prominent、背景非 accent,图标可见,未动。

### 3. 选中 note 后点 "Start Benchmark" 无反应 ✅(根因已更正)
~~原推测:canStart(isModelLoaded) 与 startBenchmark guard(whisperKit?.modelFolder) 条件不一致~~ —— **被 Mac 实测 log 证伪**:第 279 行 modelFolder guard 通过了(且 modelFolder 在 `:312` 有用,非冗余)。**真因**:选中的 note 音频未从 iCloud 同步到本机(`isAudioFileMissing` 为真——既无真实文件也无 `.icloud` 占位符),`prepareFileForReading`(`CloudStorageManager.swift:459`)在尝试下载前就返回 nil → 第 289 行 guard 瞬间静默 `return`(isRunning 一闪而过),即"点了没反应"。改:沿用 `AudioPlayerService.swift:564-573` 模式,新增 `@State startError`,失败时区分 missing/downloading 给出橙色提示(`BenchmarkView.swift`)。**注:这正是上面第一件事(iCloud 音频同步)的症状——benchmark 这里只让失败可见,根治仍需 iCloud 待办里的"文字优先、音频可见"。**

### 4. 列表只显示音频可用的 note + 已就绪/待下载状态标注 ✅
`benchmarkCandidates` 改为对每条算 `AudioAvailability`(`.ready`/`.inCloud`/`.missing`,复用 `getFileURL`+`isAudioFileMissing`+`FileManager.fileExists`),**隐藏 `.missing`**(完全没同步过来的不再出现在列表,避免盲选);保留 `.inCloud`(iCloud 有、本机未下载)。标注用 Apple 惯例(已下载不标):`.ready` **不显示任何标记**、`.inCloud` 橙色 `icloud.and.arrow.down` + "In iCloud"。选中 `.inCloud` 跑 benchmark 时 `prepareFileForReading` 自动拉取,下载阶段提示改为 "Downloading audio from iCloud…";等待中点 Cancel 不误报(`!Task.isCancelled` 守卫)。未做实时刷新(下载完图标不自动变绿,YAGNI)。经 brainstorming 与用户确认方案。

---

## ✅ 已完成(2026-06-22) — English-only 模型治理:砍 distil + medium.en,其余 .en 加标注

### 实现状态
已按下述决策实现并通过 TDD 验证:
- `ModelManager`:新增 `isEnglishOnly` / `isUnsupportedModel` / `displayNameWithLanguageTag` + `englishOnlySuffix`;`shouldIncludeModel` 接入过滤。
- UI 标注:`SettingsView`(Active Model 卡片 + 模型菜单)、`WhisperKitModelsView`(推荐行 title)、`ContentView`(主界面 + 详情页的当前模型/选择菜单)。note 的历史模型记录与 telemetry 不加标注。
- 测试:新增 `VoicelyTests/ModelSupportPolicyTests.swift`(9 用例,覆盖 `small.en_217MB`、distil turbo、`large-v3_turbo` 等边界)。完整 VoicelyTests **117 passed**;iOS Simulator 构建通过。

### 已知边界(未处理)
若老用户此前**手动选中**过 distil 或 medium.en:过滤后 `availableModels` 不再含它,但持久化的 `selectedModel` 仍是该值。`deleteModel` 的自动切换(`ModelManager.swift:416-422`)只在用户主动删除模型时触发,**不覆盖本场景**。后果:当前模型标签仍显示该模型、菜单里无法重新选回它,但**不崩溃**,已下载则仍可转录。影响面小(distil/medium.en 均非默认模型)。如需平滑迁移,可在加载模型列表后检测 `isUnsupportedModel(selectedModel)` 并切回 `platformDefaultModel`。

### 决策(已定稿)
核心 app 受众是中文用户,需防止误选 English-only 模型。经讨论确定:

- **移除**(不在模型列表中展示):
  - 所有 distil 蒸馏模型:`distil-whisper_distil-large-v3`、`_594MB`、`_turbo`、`_turbo_600MB`
    —— 体积大却是 English-only,能跑它的机器直接用 `large-v3` 多语言更好(大体积 + English-only + 有上位替代,三宗罪占全)。
  - `openai_whisper-medium.en` —— English-only 里体积最大(约 769M 参数),且相对多语言英语优势"不显著",性价比最低。
- **保留并加 `(English Only)` 标注**:`tiny.en`、`base.en`、`small.en`(含 `small.en_217MB`)
  —— English-only 的有效场景是低端机:与其装识别很差的多语言 tiny,不如装 tiny.en 把英语识别提上去;small.en 保留给中端纯英语用户。
- **保留(多语言,不变)**:其余全部(tiny / base / small / medium / large-v2 / large-v3 / 各 turbo 等)。

最终结果:列表里 English-only 只剩 3 个,且全部带 `.en` 后缀 + `(English Only)` 标注,分类清晰,不会再出现"大模型却是 English-only"的矛盾。

### 背景与依据
- Distil-Whisper 官方:所有 checkpoint 仅支持英文,不支持中文。
- OpenAI:同尺寸 `.en` 与多语言版**参数量/体积完全相同**,区别只在训练数据;`.en` 的英语精度优势在 tiny/base 明显,到 small/medium "becomes less significant"。
- 故 distil-large-v3、medium.en 这类大体积 English-only 模型对中文 app 无性价比。
- 注意:`turbo` 不是 English-only(`large-v3_turbo` 等都是多语言),别误删。
- 来源:HuggingFace `argmaxinc/whisperkit-coreml` 仓库文件树;`distil-whisper/distil-large-v3` 模型卡;`openai/whisper` README。

### 判定规则(实现用)
```swift
// 是否从模型列表中移除(distil 全系列 + medium.en)
private func isUnsupportedModel(_ model: String) -> Bool {
    let lower = model.lowercased()
    return lower.contains("distil") || lower.contains("medium.en")
}

// 是否为 English-only(移除后仅剩 tiny/base/small.en),用于加标注
static func isEnglishOnly(_ model: String) -> Bool {
    model.lowercased().contains(".en")
}
```
注意用 `contains(".en")` 而非 `hasSuffix(".en")` —— 量化变体形如 `small.en_217MB`,`.en` 后面还跟着 `_217MB`。

### 改动点
1. `ModelManager.shouldIncludeModel(_:)`(`Voicely/ModelManager.swift:513`):加入 `&& !isUnsupportedModel(model)`,过滤掉 distil 与 medium.en。
2. 列表 UI 渲染处给 `.en` 追加 `(English Only)`,**不要改 `displayName(for:)` 本体**(它被设置页 / note 标签 / 紧凑 UI 复用,且 `WhisperKitModelsView.swift:119` 会按空格拆 displayName 分行,直接加括号会污染所有 UI 并破坏分行)。涉及 `SettingsView` 的模型 `ForEach` 与 `WhisperKitModelsView`。
3. **边界**:老用户若已选中/下载了 distil 或 medium.en,过滤后 `addModel(selectedModel)`(`ModelManager.swift:169`)会因 `shouldIncludeModel` 失败而不纳入,触发 `ModelManager.swift:418` 的自动切换。需确认该降级路径平滑(自动切回平台默认或列表第一个),必要时给迁移提示。
4. 单元测试(`VoicelyTests/`,Swift Testing):覆盖 distil 全系列、medium.en 被移除;tiny/base/small.en(含 `_217MB`)保留且 `isEnglishOnly == true`;`large-v3_turbo`、`medium` 等多语言不被移除且 `isEnglishOnly == false`。
