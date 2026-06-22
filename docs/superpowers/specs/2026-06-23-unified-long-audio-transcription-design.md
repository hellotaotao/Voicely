# 统一长音频转录路径 · 设计

- 日期:2026-06-23
- 状态:已对齐,spec 后直接实现(用户预先放行)
- 触发:重新转录已有的长录音(Re-transcribe / Transcribe 按钮)走的是整段单次老路径(`transcribeWithWhisper`,`ChunkingStrategy.none`),对 1–2 小时录音重现「慢、整段进内存、无断点续传、质量漂移」的问题——而导入长音频已改用分段流水线。三条路径不一致。

## 背景与问题

转录目前有三条路径:

1. **实时录音(边录)**:增量 29s 切片(`IncrementalTranscriptionCoordinator`)。成熟。
2. **导入文件**:分段流水线(`SegmentedAudioTranscriber`)。
3. **重新转录已有录音**:`requestTranscription` → `processPendingTranscriptions` → `transcribeClaimedNote` → `transcribeAudio` → `transcribeWithWhisper`(整段单次 `.none`)。

第 3 条对长录音重转 = 整段 `loadAudioAsFloatArray` 进内存 + Whisper 原生 seek 串行,慢、OOM 风险、无续传、质量漂移。本设计让第 3 条对长录音**复用第 2 条的分段核心**,三条路径在「长音频」上统一。

## 目标与约束(已对齐)

- 长录音重转 = 分段 + 断点续传 + 进度指示 + 失败占位,**和导入完全一致**(复用 `SegmentedAudioTranscriber`)。
- **失败语义**:部分段失败 → 用新结果 + 占位;**整体失败**(全失败 / 模型未加载,即没产出任何新文本)→ **保留原有转录、不覆盖**。
- 实时录音路径**零改动**;导入路径仅改用共享 store。
- 短录音(≤30s)重转保持现有整段单次。

## 方案(Approach A:重转委托 SegmentedAudioTranscriber)

### 1. `SegmentProgressStore` 归 `TranscriptionService`
- `TranscriptionService` 新增 `let segmentProgressStore: SegmentProgressStore`,init 注入(默认 `SegmentProgressStore()`,测试可注入临时目录)。
- ContentView 的导入路径改用 `transcriptionService.segmentProgressStore`(不再自己 `@State` 持有),使导入与重转**共享同一实例** → C1 的 in-flight 防重入 guard 跨两条路径一致(同一 note 不会被导入和重转同时处理)。

### 2. `transcribeClaimedNote` 入口分流
- 在 `transcribeClaimedNote` 开头(`beginLocalTranscription` 之前)判断:
  - `note.duration > 30 && !note.audioFilePath.isEmpty` → 委托分段:
    1. `await CloudStorageManager.shared.prepareFileForReading(at: note.audioFilePath)` 确保录音本地就绪(iCloud 下载);返回 `nil` → 维持现状(等同 `audioUnavailable`:`requeueNote`,不报失败)。
    2. `SegmentedAudioTranscriber(transcriptionService: self, progressStore: segmentProgressStore).transcribe(note:sourceURL:)`(**局部实例**:`self` 被它强持有,`self` 不持有它 → 无循环引用)。
    3. `return`(跳过整段逻辑)。
  - 否则 → 现有整段单次路径,**不变**。
- 阈值 **30s**(= WhisperKit 单窗口,与导入一致)。

### 3. `removeWorkingCopy` 对重转天然 no-op
- `SegmentedAudioTranscriber.transcribe` 末尾的 `removeWorkingCopy(for: note.id)` 找的是 working-copy 目录(`Application Support/SegmentedTranscription/<noteID>.*`);重转的源是**录音文件**(在录音目录 / iCloud,非 working copy),所以 `existingWorkingCopyURL` 返回 nil → no-op,**绝不会删录音**。自动安全,无需改。

### 4. 失败语义(整体失败保留旧文本)
- `SegmentedAudioTranscriber.transcribe` 开头记录 `hadExistingTranscript = LocalTranscriptFinalizer.finalizeTranscript(note.transcription) != nil`(导入 note 转录为空 → false;重转已有转录 → true)。
- 完成时(`transcribeSegmented` 与 `finalizeSinglePass`):
  - **有新文本**(`producedAnyText == true`,含部分占位)→ 照现状写新 `transcription` + outcome(`failedRanges` 非空 → `.failed`,否则 `.transcribed`)。
  - **没产出任何新文本**(`producedAnyText == false`:整体失败 / 全 noSpeech):
    - `hadExistingTranscript == true` → **保留原 `note.transcription` 不覆盖**,outcome 维持 `.transcribed`,仅 `markTranscriptionFailure` 写内部诊断。
    - 否则 → 现状(`.noSpeech` 或 `.failed`)。
- 导入(`hadExistingTranscript == false`)行为**完全不变**。

### 5. 进度 + 续传
- 复用现有 `beginExternalTranscription` / `reportExternalProgress` / `endExternalTranscription`("Transcribing…" + 进度条)与 sidecar 续传(键为 noteID)。重转录音也能续传(录音文件持久存在,sidecar 用 noteID 记录进度)。

### 6. 导入路径
- ContentView 的 `importIncomingAudio` / `runImportTranscription` / `resumePendingImports` 改用 `transcriptionService.segmentProgressStore`。其余逻辑不变。

## 数据流(重转长录音)

```
点 Re-transcribe → requestTranscription → claim → processPendingTranscriptions
  → transcribeClaimedNote:
      duration>30s && audioFilePath 非空?
        是 → prepareFileForReading(录音) (nil→requeue)
             → SegmentedAudioTranscriber.transcribe(note, 录音URL)
                 claim / beginExternalTranscription / 分段循环 / sidecar 续传 / 写 note
                 removeWorkingCopy = no-op(录音不在 working-copy 目录)
                 整体失败 && hadExistingTranscript → 保留旧文本
        否 → 现有整段单次(transcribeAudioOutcome)
```

## 不做(YAGNI)

- 实时录音路径不动。
- 不把分段核心抽成独立 engine(Approach B)——复用现有 `SegmentedAudioTranscriber` 足够。
- 导入 note(`audioFilePath == ""`)仍不可重转(`requestTranscription` 的 `guard !audioFilePath.isEmpty`),符合「不留音频」取舍。
- 重转不为录音另建 working copy:直接只读录音文件;`extractSegment` 从录音切临时段,不改原录音。

## 开放问题

- `prepareFileForReading` 对超大录音的 iCloud 下载等待(已有 90s timeout);分段读取前需本地就绪。若下载超时 → 当作 `audioUnavailable` requeue,等下次。
- `processPendingTranscriptions` 在调用 `transcribeClaimedNote` 前已 claim;委托给 `SegmentedAudioTranscriber.transcribe` 后由它重新 claim(重设 attemptID,本机无害)——实现时确认委托后 `return`,不再走原 attemptID 校验分支。

## 测试

- **分流**:`note.duration > 30 && !audioFilePath.isEmpty` → 走分段(注入 stub 验证 `SegmentedAudioTranscriber` 被调而非整段);`≤30s` 或空 audioFilePath → 整段。
- **整体失败保留旧文本**:note 有旧转录,分段全部段失败(`producedAnyText == false`)→ 旧 `transcription` 保留、不被覆盖,outcome 仍 `.transcribed`,诊断写入 `transcriptionLastErrorMessage`。
- **部分失败用新结果**:有新文本 + 个别占位 → 写新结果(outcome `.failed`),不回滚到旧文本。
- **导入不受影响**:导入(无旧文本,`hadExistingTranscript == false`)整体失败 → 仍 `.failed` / `.noSpeech`。
- **共享 store**:`TranscriptionService.segmentProgressStore` 与导入用同一实例(in-flight guard 跨路径一致)。
