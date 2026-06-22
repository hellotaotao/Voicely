# 长音频导入分片转录 · 设计

- 日期:2026-06-22
- 状态:待评审
- 触发:从系统录音机等 app 经 Share Sheet 导入的整段长音频(可能 1–2 小时),目前复用了为「实时录音 ≤29s 预切片段」设计的整段单次转录路径,在长音频上慢、吃内存、质量不稳、且中断即全部丢失。

## 背景与问题

导入路径(`ContentView.importIncomingAudio`,`ContentView.swift:623`)与正常录音**共用同一个** `transcribeWithWhisper`(`TranscriptionService.swift:780`),其 `DecodingOptions` 写死 `ChunkingStrategy.none`(`:876`)。该参数是为「我们自己的 neural VAD 已把实时录音预切到 ≤29s、每段单窗口」而设。但导入的整段长音频也被迫走这条路:在 `.none` 下,WhisperKit 会把整段一次性 `loadAudioAsFloatArray` 读进内存(`WhisperKit.swift:856`),再用 Whisper 原生 timestamp-based seek 串行逐 30s 窗口转完(`TranscribeTask.swift` seek 循环,`seek` 由解码出的 `lastSpeechTimestamp` 推进)。

它**不会**截断到 30s、也**不会**失败,但代价集中在五点:

1. **慢**:串行,未并行(且端上 ANE 共享,并行收益本就有限)。
2. **内存**:整段进内存(1h≈230MB,2h≈460MB)+ 模型 + mel,旧设备有 OOM 风险。
3. **质量**:同时显式关闭了 temperature fallback(`temperatureFallbackCount: 0`),长音频一旦陷入重复/幻觉无法自恢复。
4. **全有或全无**:整段一条 note、一次 attempt,中途崩溃/被系统挂起即前功尽弃,无断点续传。
5. **生命周期**:转录在前台 Task,无后台保护,锁屏/切走即中断。
6. **多余的存储与同步**:导入即把文件 `copyItem` 复制进 `CloudStorageManager` 管理、参与 iCloud 同步的音频目录(`CloudStorageManager.swift:257`),长期占空间并上传——但该音频本是用户在别处录的、只为转录借入,这份副本与跨设备同步并无必要。

## 设计目标与约束(已与用户对齐)

- 主力场景:**经常导入 1–2 小时**长录音。
- **后台尽量 + 断点续传**:后台能多转一点是一点,真正保证最终完成的是「中断后回前台自动续」。
- 正常实时录音路径**零改动**。

## 方案总览

新增 `@MainActor` 组件 **`SegmentedAudioTranscriber`**,只处理「已完整的音频文件」:分段 → 逐段转录 → 持久化进度 → 断点续传 → 拼接。切片粒度与逻辑**复用正常录音已验证的 15–29s neural VAD 静音切点**;每段 ≤30s,即 WhisperKit 单窗口,不触发其内部 seek。

分流(仅改导入路径):

```
importIncomingAudio → 建 VoiceNote → 读 duration
    ├─ duration > 30s(= WhisperKit 单窗口)→ SegmentedAudioTranscriber  ← 新增
    └─ ≤ 30s                               → 现有 transcribeClaimedNote  ← 不变(整段即单窗口)
正常实时录音:IncrementalTranscriptionCoordinator                        ← 不变
```

**为什么以 30s 为界、而非某个分钟数:** 老路径的内存(线性,≈62.5 KB/s)、中断损失、质量漂移都随时长平滑变化,没有天然拐点,任何分钟数都是拍脑袋。唯一有物理依据的界是 30s = WhisperKit 单窗口:≤30s 本就是一个窗口,切不切等价,分段框架纯属多余;>30s 才首次出现「自己用 neural VAD 切」vs「丢给 WhisperKit 内部 seek」的真实差别。故以 30s 分流。

**为什么是 15–29s 全程 neural VAD,而非更大的段交给 WhisperKit 内部 seek:**

- 总 30s 窗口数 = 总时长 / 30s,固定;大段并不省算力(只是把窗口边界的决定权交给 WhisperKit 的 timestamp seek)。
- 正常录音已证明「独立 29s 段 + 换行拼接」质量可接受(`IncrementalTranscriptionCoordinator.swift:245` 每段独立 `transcribeAudio`、无跨段 prompt,该路径已成熟)。
- 全程自切可把所有边界交给最精确的 neural VAD(优于 timestamp seek 与 `.vad` 的 EnergyVAD),内存最稳、续传最细,并直接复用现有代码。

## 详细设计

### 1. 组件结构(单一职责、可独立测试)

- **离线驱动循环**:对已完整文件,从 `lastFrame` 循环推进到文件尾。与实时协调器的唯一区别在驱动方式(timer + 不断增长的文件 → 循环到结尾)。
- **复用现有 `static` 底层**:`extractSegment`(`IncrementalTranscriptionCoordinator.swift:350`,按帧切临时文件)、`voiceActivityAwareCutFrame`(`:395`,VAD 静音切点,范围参数化)、`sanitizedSegmentText`、累积拼接逻辑。
- 沿用 `transcribeOverride` 注入点,便于单测。
- 实时协调器一行不动,降低对成熟路径的风险。

### 2. 分段与转录

- 每段:`voiceActivityAwareCutFrame` 在 15–29s 找静音切点 → `extractSegment` 切临时 WAV → `transcribeAudio(filePath:)` → 转完删临时文件。
- **内存安全**:任一时刻只持有一个 ≤29s 临时段(几 MB);WhisperKit 加载的也只是这个短文件。
- **decode 选项**:沿用与正常录音一致的逐段选项(见「不做」中关于 fallback 的说明)。每段 ≤29s 单窗口,行为与成熟的正常录音路径完全一致。

### 3. 进度持久化(本地 sidecar,不走 CloudKit)

- **位置**:`Application Support/SegmentedTranscription/<noteID>.json`。
- **内容**:`{ lastFrame, totalFrames, accumulatedText, failedRanges: [{start,end}], updatedAt }`。
- **时机**:每段完成后写一次。
- **完成**:全部段处理完,才把最终文本写入 `VoiceNote.transcription` 并 `completeTranscription()`,随后删除 sidecar。跨设备永远看不到半成品。
- **零 SwiftData / CloudKit schema 变更**:是否需要分段重转,靠 `VoiceNote.duration > 30s`(现有字段)判断;是否有未完成任务,靠 sidecar 是否存在判断。不新增任何同步字段。

### 4. 断点续传

- 转录中:note = `claimed`,本机持 lease + heartbeat(复用 `startLeaseHeartbeat`,`TranscriptionService.swift:742`)。
- **触发**:`scenePhase` 变 `.active`(app 启动 / 回前台)时扫描 sidecar 目录;对存在 sidecar 且对应 note 属于本机 / 未完成者,从 `lastFrame` 续。
- 崩溃 / 被杀:lease 过期,但 sidecar 仍在 → 回前台识别为本机未完成任务 → 续。
- **孤儿清理**:启动扫描时,sidecar 对应 note 已不存在 → 删 sidecar。

### 5. 后台

- 用 `beginBackgroundTask` 包住段循环;因每段完成即持久化,可在后台时间耗尽前停于干净段边界并 `endBackgroundTask`。
- 平台差异:Mac Catalyst 不挂起 app,后台非问题;此机制主要服务 iOS。
- 预期管理:iOS 后台通常只够转数段,最终完成依赖续传,后台仅「能多转一点是一点」。

### 6. 错误处理(对接 outcome spec)

- 单段 `whisperError`:重试该段 2 次。
- 仍失败:把该段帧范围记入 `failedRanges`,**跳过、继续**后续段。
- **失败段在文本中诚实占位**:跳过的段在拼接结果的对应位置插入带时间范围的占位(如 `[00:12:30–00:13:05 这段未能转录]`),占位置、明确告知,不静默吞掉。
- 全部处理完:`failedRanges` 非空 → outcome = `failed`(可重试,且**重试只补 `failedRanges`**);否则 `transcribed`。
- 全段均 noSpeech → outcome = `noSpeech`。
- **UI**:对接 `docs/superpowers/specs/2026-06-22-transcription-outcome-handling-design.md`,平静卡、无红色 "needs review";部分失败提供「重试(只补未成功段)」。
- 用户取消:停于段边界,保留 sidecar(下次可续)。

### 7. 进度显示

- 进度 = `lastFrame / totalFrames`,经现有 `progressByNoteID` 与平滑机制呈现。
- 可附「已转 X / 共 Y 分钟」。

### 8. 导入文件的存储策略(不进 iCloud、用完即焚)

导入的音频本是用户在别处录的、只为转录借入,Voicely 不必长期保存,也不必同步到 iCloud。

- **不再复制进同步目录**:导入不走现有 `importAudioFile` 那条「复制进 `CloudStorageManager` 同步目录」的逻辑。
- **转录期间用本机非同步临时副本**:在本机、不参与 iCloud 同步、也不会被系统自动清理的区域转存一份工作副本(与 sidecar 同处,如 `Application Support/SegmentedTranscription/` 并设 `excludeFromBackup`;不可放 `Caches`——低存储时会被系统清除、毁掉续传),供分段读取与断点续传。原因:Share 提供的是 security-scoped 原文件 URL(`CloudStorageManager.swift:232`),其访问权在 app 重启后失效,无法依赖它跨重启续传;故须自留一份可控的工作副本。
- **转录完成 / 取消 / 放弃失败 → 删除临时副本**,用完即焚,不长期占空间。
- **note 默认无持久音频**:`VoiceNote.audioFilePath` 转录期间指向临时副本,完成后置空;UI 对这类 note **隐藏播放控件**(音频原件仍在来源 app)。
- **适用范围**:默认对所有导入生效(无论时长)。
- **实现注意**:现有不少代码假设 `audioFilePath` 非空且指向同步目录;需审查导入 note 的播放、同步状态、删除等路径,避免空音频路径引发异常。
- **YAGNI / 未来**:如确有需求,可加「导入时保留音频」开关;当前默认不保留。

## 数据流

```
分享导入 → importIncomingAudio 建 VoiceNote、读 duration、转存本机临时副本(不进 iCloud)
  └ duration>30s → SegmentedAudioTranscriber.start(note)
        1. 读 sidecar:有→从 lastFrame 续;无→从 0
        2. claim note + lease heartbeat + beginBackgroundTask
        3. 循环到文件尾:
             VAD 15–29s 找静音切点 → extractSegment 切临时段
             → transcribeAudio(≤29s 单窗口) → 删临时段
             → 成功:追加文本、推进 lastFrame、写 sidecar、报进度
             → 失败:重试 2 次 → 仍败记入 failedRanges、继续
        4. 到尾:拼接全文(失败段插占位)→ VoiceNote.transcription + completeTranscription
                 → outcome(transcribed / 有 failedRanges 则 failed)→ 删 sidecar + 删临时音频副本
  └ 被挂起/杀:sidecar 已存最新进度 → scenePhase 回 .active → 扫描 → 续
```

## 不做(YAGNI)

- **多 worker 并行转段**:端上 ANE/GPU 共享,收益有限且放大内存。
- **跨段 prompt 上下文接续**:正常录音也没有,质量已可接受。
- **跨设备续传**:导入文件在本机,sidecar 亦本机。
- **3 分钟大段 / 交给 WhisperKit 内部 seek**:不省算力且边界不可控。
- **单段 temperature fallback 差异化**:每段已是 ≤29s 单窗口,长音频 fallback 痛点已被「全程自切」消除;保持与正常录音一致即可,如后续确有单段重复再加。
- **iOS 长时后台音频模式**:不为转录申请 background audio,完成依赖续传。

## 开放问题

- **导入格式兼容**(实现期验证):别的 app 导出的音频可能是 m4a / mp3 等格式;按时间切片的代码(`extractSegment`,基于 `AVAudioFile`)需确认对这些格式都适用,个别格式可能要先转码成统一 PCM 再切。

## 测试

- **分流**:duration > 30s → 分段;≤30s → 整段单次(注入 duration)。
- **分段循环**:给定 N 帧 → 切出预期段数、`lastFrame` 单调推进至尾。
- **续传**:预置中途 `lastFrame` 的 sidecar → 从该段续、前序段不重转(用 `transcribeOverride` 计数断言)。
- **单段失败**:注入第 k 段失败 → 重试 2 次 → 记入 `failedRanges` → 继续 → outcome=failed,其余段文本完整。
- **完成**:全成功 → 拼接 = 各段顺序拼接 → `completeTranscription` 被调用 + sidecar 被删除。
- **noSpeech**:全段无语音 → outcome=noSpeech、不报错、不写 error message。
- **取消**:中途取消 → 停于段边界 → sidecar 保留、可续。
