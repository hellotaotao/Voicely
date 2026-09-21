# Voicely 开发路线（唯一事实源）

> **这是本仓库唯一的 roadmap 与 To Do。** 原先散在 `todo.md`、`AGENTS.md` 的待办已全部合并到这里。
> 其他文档若与本文件冲突，一律以本文件为准。
> 历史执行/验证记录已剥离到 [roadmap-log.md](roadmap-log.md)，本文件只写"要做什么、做到哪一步"。
>
> 状态标记最后核对：**2026-09-13**，逐条按当前 `dev` 分支代码核实，不凭记忆。**2026-09-19** 补记 0.23.9 已提交、0.23.10 录音收尾修复（P-0）与 stash 回退（P-6）；**2026-09-20** 补记 build 4 手动重转录后台支持（P-0a）；**2026-09-21** 补记 0.23.11 prompt 回声与收尾修复（P-0b）、后台任务停滞判定（P-0c）。

标记含义：✅ 已完成 · 🚧 进行中 · 🧪 代码就位、真机验收未做 · ⬜ 未开始 · ⚠️ 部分完成

---

## 一、当前状态一览

| 阶段 | 范围 | 状态 | 核实依据 |
| --- | --- | --- | --- |
| ① 收敛基线 | 0.23.1 + 有限 Whisper 温度重试 + 逐段预览 | ✅ | 已提交至 `dev`（`6cc7c75`…`575b9b4`） |
| ② 关键可靠性 | 保存、转码失败、收尾、取消、队列、断点恢复 | ✅ 实现<br>🧪 真机 | `7899dea`；Mac 实测通过，iPhone 真机本轮被明确豁免 |
| ③ **定时停止与延长** | 按时长/结束时刻自动停止，提前提醒，随时延长 | ⬜ **下一个** | 代码无 `autoStop`/`countdown` 相关实现 |
| ④ 千问主力版本 | 中文及中英混说完整闭环 | ⬜ | `Vendor/speech-swift` 存在，但 `project.pbxproj` 零引用，未接入工程 |
| ⑤ Mac 专项 | 多声道转换 + 无信号提示 | ⚠️ | 手动 mixdown 已实现（`AudioRecordingService.swift:610`）；**录音中**实时无信号提示仍缺，只有录完后的静音提示 |
| ⑥ 预约提醒录音 | 本地通知提醒，点通知打开准备界面 | ⬜ | 无 `UNUserNotificationCenter` 调用 |
| ⑦ 反馈驱动的增强 | 系统入口完善等 | 🧪 | Live Activity / Shortcut / DeepLink 文件均已存在，真机验收未做 |

**版本现状（2026-09-19）**：0.23.9 已于 09-11 上传 TestFlight，当时是从未提交的工作区直接打包的，源码 09-19 补提交为 `aaf8002`。0.23.10 = 录音收尾修复（P-0），build 4 另含手动重转录后台支持（P-0a）。0.23.11 = prompt 回声与收尾修复（P-0b）+ 后台任务进度上报（P-0c）。以上均待真机验收。0.23.8 起的版本都**不含** 0.23.5–0.23.7 的改动（见 P-6）。

---

## 二、总原则

以 0.23.1 的实际使用体验为基线，小步演进现有程序；不重写，不整体合并 0.24.0 的未发布功能。每次只交付一个主要用户收益，在内部 TestFlight 实际使用后再推进下一项。

### 每版交付规则

1. 写清一个主要用户收益、范围、排除项、验收条件。
2. 在 `dev` 上实现明确范围，保留 `old-dev` 作为参考。
3. 实现与相关回归测试一起完成，不做纯功能半成品合并。
4. 运行测试、真机验收、上传内部 TestFlight。
5. 用户实际使用；出现问题优先修复，不夹带新功能。
6. 当前版本验收通过后，再开始下一主要功能。

### 不单独扩大发布范围

- Whisper 模型目录先保持基线；新档位单独验证再加入。
- Mac 麦克风修复按平台处理，不与 iPhone 功能绑定。
- Live Activity/Shortcut 验收已有行为，不当成新功能重做。
- 性能问题先测量；优化限定于本版受影响路径。

### 明确不排期

Apple Watch、智能自动停止（听到告别语+静音判定会议结束）、AI 摘要、更多模型档位、数据库替换。

**词级时间戳 / 点词同步也在此列。** `todo.md` 曾把它列为待办（拖动录音文字跟随、长按词跳播放），与本路线的"暂缓点词同步"冲突；按本文件为准，**暂不排期**。相关实现留在 `old-dev`，当前 `dev` 无 `TappableTranscriptView`/`wordTiming` 代码。

---

## 三、阶段详情

### ③ 定时停止与延长（下一个交付）

从原第五位提前。理由：开会结束后忘记停止，会留下大量多余录音，后续还要转录和剪辑，这是当前最痛的一个问题。不等待千问或 Mac 专项。

范围：

- 开始录音时可选择录音时长（例如 30、60 分钟，支持 35、41 分钟等自定义值），或指定结束时刻（例如 10:00）。
- 录音界面显示预计结束时间和剩余时间；结束前提醒，提前 3 分钟作为待确认的初始建议。
- 录音期间可一键延长（例如 10、15 分钟）、修改结束时间或立即停止。
- 无操作时按计划停止并保存，衔接现有转录流程。

排除：预约自动开始、重复计划、智能停止。

验收：不能只覆盖前台倒计时，**必须包含真机锁屏、切换 App、延长和停止后的保存收尾**。

涉及：`Voicely/ContentView.swift`、`Voicely/AudioRecordingService.swift`、`Voicely/RecordingActivityAttributes.swift`

### ④ 千问主力版本

中文及中英混说，完整下载/加载/长音频/恢复闭环。排除自动模型路由、逐词定位。
验收：同一 iPhone 的质量、速度与资源测试；通过后发布。

现状：`Vendor/speech-swift` 目录在，但没接进 Xcode 工程，等于从零接线。

### ⑤ Mac 专项

多声道转换 ✅ 已完成（DJI 立体声缩混，已实测）。剩余：**录音过程中的实时无信号提示**。排除已撤回的 AVCaptureSession 实验。

### ⑥ 预约提醒录音

已收敛为"提醒"，不做全自动后台启动：

- 用户设置单次或重复提醒，例如每天或每个工作日 9:00；支持跳过某次。
- 使用 iOS 本地通知，由系统按计划提醒，不依赖服务器推送。
- 点击通知后打开录音准备界面，带入该计划的结束时间或时长；**此时不启动麦克风**。
- 用户点"开始录音"才实际录制，复用③的自动停止、提醒及延长。
- 按结束时刻设置时（如 10:00），晚于 9:00 开始仍以 10:00 为结束目标；点击时计划已过期则先让用户确认新时间。

验收：通知授权、单次及重复提醒、取消与跳过、App 未运行时点通知的导航，以及点通知不会自动开始录音。

参考：[Apple 本地通知调度文档](https://developer.apple.com/library/archive/documentation/NetworkingInternet/Conceptual/RemoteNotificationsPG/SchedulingandHandlingLocalNotifications.html)

### ⑦ 反馈驱动的增强

Live Activity / Dynamic Island 录音状态、Start Voicely Recording 快捷指令 / 操作按钮指派路径——代码已在 `Voicely/RecordingLiveActivityController.swift`、`VoicelyWidgets/`、`Voicely/StartRecordingIntent.swift`、`Voicely/VoicelyDeepLink.swift`，**只差真机验收**。

一项做完整，发布后再做下一项。

---

## 四、跨阶段待办

不绑定某个阶段编号，按优先级排。原 `todo.md` 与 `AGENTS.md` 的条目已合并至此并逐条核实过。

### P-0 🧪 录音收尾：一段失败不再整篇重转（0.23.10）

0.23.9 真机现象（09-17 一场 5:04 的会议，锁屏录音）：停止后界面仍写 "Recording — transcript updates live"；退出再进变成从头开始的整篇重转（进度 5%、速度从 1.1× 跳到 2.8×，其实是第二次运行）；取消后列表显示 Queued、详情显示 cancelled。

根因（均早于 0.23.9）：
- 实时转录任何一段失败（Whisper 报错、复读、取消、模型不可用）都会设 `requiresFullTranscription`，收尾时丢掉已转好的全部文字、整篇重新排队（0.23.2 `6cc7c75` 引入）。
- 重转沿用手动 re-transcribe 的规则：旧稿一直显示、全部成功才替换，只要有一段失败新结果整个作废（6 月 `72e2c4b`）。
- 标签判定"有文字就算实时转录中"，"Finalizing" 却要求没有文字，所以收尾阶段永远显示成录音中（5 月 `a015f71`）。

用这场会议的真录音在 Mac 上重放（`RealRecordingReplayTests`，small 模型）：结尾道别那段（4:38–5:04）会让 Whisper 陷入 "Thank you. Bye." 复读，被 `repetitive output` 判为失败，记录了失败原因的 9 次运行里有 4 次出现。放在 0.23.9，这一段就足以触发整篇重转。

0.23.10 的改动：
- 实时失败的段记下时间范围，停止时原地重试 2 次，按原位置拼回；仍失败则标成 `[m:ss–m:ss transcription unavailable]`，note 记为 failed 并写明段数；只有模型不可用/音频读不到/取消这类"根本没法解码"的情况才走老的整篇排队。
- 停止后显示 "Finalizing transcription…"；录音中、收尾中、转录中都不显示 Re-transcribe（点了本来也会被拒）。
- 频谱（WhisperKit 默认 CPU+GPU）和 Silero VAD 不再用 GPU——iOS 后台不允许 GPU。
- 收尾剩余音频 ≥ 20 秒时申请 iOS 26 `BGContinuedProcessingTask`（系统进度条，锁屏后继续跑）；拿不到就退回原来约 30 秒的 `beginBackgroundTask`。
- 0.23.10 (2) 另含：音频会话的激活/停用从主线程移到一个串行队列（Xcode 报 `AVAudioSession Hang Risk`；异步激活 API 要 iOS 27，最低支持 17.6 用不了），录音预热、开始录音、播放都在队列上等待激活，停止和暂停时的停用排队执行；恢复录音那条少见路径仍同步。删除 `AVAudioPlayerDelegate` 上多余的 `@preconcurrency`。
- 0.23.10 (3) 另含：停止时的剩余量把正在转录、尚未完成的分片算进去（原来漏算，实时转录跟得上时几乎总是低于 20 秒门槛，不会申请后台继续处理）。门槛和转录/重试/取消逻辑不变。

真机验收（Mac/模拟器测不了锁屏）：
1. 锁屏录 5 分钟以上的会议，解锁、停止、立刻再锁屏：回来时稿子完整、没有整篇重转。锁屏上**不一定**出现 "Finishing transcription" 进度——只有停止时剩余音频（没转到的 + 正在转的 + 实时失败待重试的）≥ 20 秒、且系统接受申请时才会出现；否则靠 iOS 给的有限后台时间（通常约 30 秒，不保证）。
2. 停止后详情页显示 "Finalizing transcription…" 而不是 "Recording"。
3. 若出现 `[… transcription unavailable]` 标记，记下是哪段、什么内容。

### P-0a 🧪 手动 Re-transcribe 锁屏继续与中断恢复（0.23.10 build 4）

用户长期真机使用已确认：旧版手动 Re-transcribe 锁屏后通常无法继续完成，不需要重新验证旧现象。

本轮范围：为用户启动的保存音频转录接入 iOS 26 continued-processing task，报告实际进度；任务被拒绝或过期时保留已完成分段与旧正文，回前台恢复。用户主动取消仍不自动恢复。录音实时转录和停止后的收尾路径保持不变，不整体恢复 P-6 的 stash。

GPU 配置没有后台 GPU entitlement，保持前台运行并明确提示；默认 CPU/Neural 配置申请后台执行。Mac Catalyst 不应用 iOS 挂起限制。

验收：自动化验证和 archive 记录见 [roadmap-log.md](roadmap-log.md)。真实 iPhone 待验证新包：前台点 Re-transcribe 后锁屏，确认能否在锁屏期间完成；系统中断后解锁，确认从已保存分段继续，完整成功才替换旧稿。

### P-0b 🧪 自定义 prompt 引发的分段失败与收尾卡死（0.23.11）

0.23.10 (3) 真机跑长录音暴露的三件事，根因不在收尾逻辑本身：

- **自定义 prompt 是分段失败的主因。** `transcriptionPrompt` 被 prefill 进**每一个** ~29 秒分片。停顿、翻页、远处杂音这类没有可懂语音的分片上，Whisper 直接把 prompt 吐回来、经常还复读，压缩比撞上 8.0 的门槛 → `repetitive output` → 整片判失败。用户实测 63 分钟报 22 段、40 多分钟报 9 段，约 11%–17%，比例稳定，符合内容相关的系统性失败而非偶发故障。
- **重试是确定性的，等于白跑。** 同一段音频 + `temperature: 0.0` + 同一模型，连跑 3 次结果完全一样。收尾时每个失败分片重试 2 次 = 大量无用解码，把"停止录音"从瞬间拖成几分钟；用户在这期间锁屏，continued-processing task 到期弹 "Finalization failed"，app 被挂起，收尾冻在半路。
- **实时分片只存在内存里。** 收尾路径既不写 checkpoint 也不主动让步给后台（重转录路径两样都有）。app 被 iOS 杀掉后，`isTranscribing=true` 已经持久化，而启动时没有任何代码清理它 → note 永远显示 "Finalizing"。

0.23.11 的改动：

- 解码器自己处理 prompt 的失败模式：首遍输出被判定为 prompt 回声或复读时，**去掉 prompt 再解一遍**。第二遍可用就用第二遍；仍复读才算 `repetitive output`；两遍都没有可懂内容则记为 `noSpeech`（这类分片是噪音，不该让整条 note 失败）。
- 收尾重试次数 2 → 1。prompt 相关的重试已经下沉到解码器内部，外层多跑的那次只是同样的输入过同样的模型。
- 每个失败分片保留 Whisper 的原始 diagnostic，note 的失败信息写成 `N segment(s) failed after retry: repetitive output ×7, blank output ×2`。Release 构建没有 debug log，这是唯一能带出原因的地方。
- 启动时回收被杀在收尾中途的 note：保留实时转出的文字，清掉假的 "Finalizing"，标为 failed 并说明收尾被中断；要不要重转由用户决定。

真机验收：
1. **保留现在的自定义 prompt**，录一段有明显停顿的长会议，看失败段数是否明显下降。
2. 若仍有失败，记下新的失败信息里各个原因的分布——这决定下一步是继续调 prompt 处理还是动 `repetitive output` 的门槛。
3. 停止录音到 note 落定的耗时是否明显缩短；锁屏后是否还弹 "Finalization failed"。

### P-0c 🧪 锁屏后 continued-processing 任务被判"停滞"收走（0.23.11）

0.23.10 (4) 真机：锁屏重转 20 多分钟的录音，锁屏进度跑到约 4% 就弹 "Transcription failed"。`sudo log collect` 拉的设备日志里，三次后台运行全是同一个死法，dasd 原话：

```
Task has not reported progress within expected cadence, marking stalled (time without update: -34.6)
{name: Activity Progress Policy ... tracker.health == 2}, Decision: AMNP
Suspending ... - required criterion is not satisfied.
```

任务是**拿到了**的（submit 后 1 ms 内就 launch，锁屏进度条也出来了），被收走是因为约 30 秒没有进度更新。根因：WhisperKit 只在一个解码窗口结束时推进 `progress`（`TranscribeTask.swift` 窗口循环末尾），而我们每个 ≤29 秒的分片正好是一个窗口，所以整片解码期间进度停在 0。锁屏状态下一个 29 秒分片要解约 40 秒，超过 dasd 的节奏阈值。录音收尾（P-0 那个 "Finalization failed"）也是同一个原因：它的进度只按分片落定推进。

0.23.11 的改动：

- 从 Whisper 解码过程中吐出的时间戳 token 读出"已经解到窗口里第几秒"，作为分片内的真实进度。时间戳大约每几秒音频一个，节奏远低于 30 秒。只对单窗口音频（≤30.5 秒）启用，多窗口时时间戳会按窗口重置、量不准。
- 重转录路径把分片内进度映射成整个文件的进度；收尾路径把正在解码的分片的部分帧计入 `finalizationProgress`。两处都只前进不后退（温度回退、去掉 prompt 重解都会让解码器从 0 重来）。
- 后台任务结束时，"跑完了但有几段读不出来"报成功，只有跑完了一个字都没有才报失败。暂停/过期仍报失败（活确实没做完）。

真机验收：
1. 锁屏重转一段 20 分钟以上的录音，看能撑多久。如果仍被收走，再导一次日志，看是不是换成了别的理由（例如热量、时长上限）。
2. dasd 给这类任务标的是 `UserInitiated, 900s`，是否等于 15 分钟硬上限未确认。锁屏解码大约 0.7× 实时，20 分钟录音要约 28 分钟，可能仍需一次解锁续跑——checkpoint 在，不会从头来。

### P-1 ⚠️ 转录指标：time ratio 与 speed 一直停在 "Measuring"

re-transcribe / 整文件转录时这两个值出不来；live transcription 正常。根因是分段路径没接遥测会话。

**已随 0.23.9 发出**（`aaf8002`）：`TranscriptionTelemetry` 增加 `processedAudioSeconds` 与区间合并，`SegmentedAudioTranscriber` 接入 `telemetrySession`，遥测快照按 `noteID` 隔离避免串台。

遗留：分段路径（>30 秒，即几乎所有真实录音）转完后不把速度写回 note——`SegmentedAudioTranscriber` 里没有 `recordTranscriptionTelemetry` 调用，re-transcribe 也不清旧统计。结果是长录音重转完成后，速度徽章仍是上一次的数字，模型名却已是新的。

### P-2 ⬜ 转录完成后指标整块消失 → 改为可折叠

转录中有 speed / time ratio，一完成整块就没了。方案：做成可折叠——进行中自动展开，完成后自动折叠收起，指标仍在，点开即看。
核实：代码中无对应 `DisclosureGroup`，未实现。

### P-3 ⬜ iCloud 同步：文字优先，音频延后

积压多天未同步时列表迟迟不一致，怀疑被大音频拖住。诉求：先把 notes + 转录文字同步进来让列表一致，音频按需下载。

现状（已查证）：两通道**本就独立**——SwiftData+CloudKit 走列表，音频走 iCloud Documents 且已是按需下载（`prepareFileForReading`），全量 `forceDownloadAll` 只在用户主动点击时触发。所以瓶颈不在"音频抢占"这个直觉上。

待调查：

- 定位"列表迟迟不一致"的真实瓶颈：是 CloudKit 初次拉取 note 记录本身慢（可能正常），还是 UI 在等音频元数据才渲染。
- 确认 note 行渲染完全不依赖本地音频存在。
- 同步状态 UI 区分"文字已同步 / 音频待下载"。
- 排除启动即批量 `startDownloadingUbiquitousItem` 间接抢带宽的路径。

### P-4 ⚠️ 收紧生产日志

`AudioRecordingService`、`AudioPlayerService` 已清理干净（0 处裸 `print`）。剩余：`CloudStorageManager` 20 处、`VoicelyApp` 13 处仍未用 `#if DEBUG` 包住。

### P-5 ⬜ English-only 模型的老用户迁移（已知边界，影响面小）

若老用户此前手动选中过 distil 或 medium.en：过滤后 `availableModels` 不再含它，但持久化的 `selectedModel` 仍是该值。`deleteModel` 的自动切换只在用户主动删除模型时触发，不覆盖本场景。后果是当前模型标签仍显示该模型、菜单里选不回去，但**不崩溃**，已下载则仍可转录。
修法：加载模型列表后检测 `isUnsupportedModel(selectedModel)` 并切回 `platformDefaultModel`。

### P-6 ⬜ 0.23.5–0.23.7 的改动还在 stash 里，0.23.8 起的版本都不含

09-10 修卡顿前，按当时的约定把未提交的 0.23.5–0.23.7 改动暂存为 `stash@{0}`（`pre-ui-performance-fix-20260910`），准备真机测完 0.23.8 再放回，但一直没放。内容：手动转录的后台继续处理（`OfflineTranscriptionBackgroundManager`，iOS 26 `BGContinuedProcessingTask`，只管手动触发的已保存音频转录，不管录音）、段内进度显示、诊断面板、外层重试/`unusableOutput` 调整。0.23.7 二进制里有 `OfflineTranscriptionBackground` 符号，0.23.8/0.23.9 没有。

0.23.10 的录音收尾已单独接上 `BGContinuedProcessingTask`（`ContinuedProcessingTask.swift`，思路取自 stash），build 4 又独立补上手动重转录后台支持（P-0a），没有恢复整个 stash；其余内容要不要放回待定。09-18 只读模拟：放回 0.23.9 工作区有 7 个文件冲突。**不要 drop 这个 stash。**

---

## 五、已完成，可从待办中划掉

2026-09-13 逐条核实，`AGENTS.md` 旧 To Do 中以下各项已在代码中落实：

| 旧条目 | 核实结果 |
| --- | --- |
| 用真实进度替换模拟转录进度 | ✅ `TranscriptionService` 中 `simulat*` 符号已全部消失 |
| 修复 `processPendingTranscriptions` 跳过笔记 | ✅ 已改为入队 + `needsReprocessing` 重排 + 等待活跃任务；测试 `queuedNoteAddedDuringActiveProcessingIsDrainedBySameLoop`、`pendingQueueWaitsForExternalOwnerInsteadOfSkippingNote` |
| 确保模拟进度任务在提前退出时取消 | ✅ 随模拟进度一并移除 |
| 接上 `showLoadModelPrompt` 并跳转设置 | ✅ `ContentView.swift:1627` 弹窗 + `:2370` 触发 |
| iCloud 音频下载健壮性 | ✅ 等待下载、失败可见、300 秒重试窗口（F-002）已实现；剩余的"文字优先"另列为 P-3 |
| iCloud 启用时自动启动 metadata query | ✅ `CloudStorageManager.swift:66/81` 自动调用 `setupMetadataQuery()` |
| 移除无用的 `currentRecordingPath` | ✅ 符号已不存在 |
| 补"转录进行中再来一个"的测试 | ✅ 见上方队列测试 |
| 分段转录应边转边出、不等整篇 | ✅ ① 阶段的逐段预览已实现 |
| Settings Benchmark 三个问题 + 音频可用性标注 | ✅ 2026-06-22 完成 |
| English-only 模型治理（砍 distil + medium.en，其余加标注） | ✅ 已实现并有 9 个单测；遗留边界见 P-5 |
| DJI / Mac 立体声录音全零 | ✅ 手动 mixdown 已修复并实测 |

---

## 六、基线与备份（历史参考）

- 开发分支 `dev`，起点 `6f3681baa2658b1bc774677e421546dee2f10c63`，采用归档后整理的版本配置提交 `6f3681b`。
- 版本源：`Config/Version.xcconfig`（当前 `0.23.10 (4)`）。**只在这里改版本号**，app 与 widget 共用，不要在 Xcode target 里改。
- `old-dev` 保持在 `dea04f11eacb23e1a6a65e9a90f53ceba1a0afa8`，未重置。旧 dev 的未提交修复保存为 stash，由 `backup/pre-r0-20260907` tag 固定引用；本地备份目录 `build/backups/pre-r0-20260907/`（含 `working-tree.tar.gz`、`manifest.json`、`changes.patch`、`history.bundle`，均已校验）。

恢复旧开发状态（工作区干净时）：

```sh
git switch old-dev
git stash apply --index backup/pre-r0-20260907
```

不要在稳定分支应用整个备份。后续只移植明确属于单一需求的实现与回归测试。

R0 验收剩余未完成项：真实 iPhone 升级后旧音频与文字可读；录音/暂停/停止/回放/转录/编辑/iCloud 的真机走查；核对 App Store Connect 版本号后发内部 TestFlight。

---

## 七、发布注意

- 共享 scheme 的 Archive 已没有 pre-action（`16a7c37` 起），archive 不再自动 `git tag`/`git push`。0.23.4–0.23.9 因此都没有 tag；0.23.9 更是从未提交的工作区打的包。以后先 commit 再 archive，版本和提交才对得上。
- 0.23.10 为 `BGContinuedProcessingTask` 在 `UIBackgroundModes` 里加了 `processing`（与 stash 里的实现一致；SDK 文档只对 `BGProcessingTask` 明确要求它）。首次公开发布前确认它是否必需，不需要就去掉，免得审核追问。
- 上架材料在 [app-store-release/](app-store-release/)。注意 `release-checklist.md` 里写的 `MARKETING_VERSION = 0.15.3` 已过时，且版本源已迁至 `Config/Version.xcconfig`，以 xcconfig 为准。
- Voicely 从未正式上架，只发过 TestFlight，下次提交是首次公开发布而非更新。
- `app-store-release/widget-shortcuts-roadmap.md` 中的 Phase 编号属于早期系统入口专题规划，**不代表本文件的 ①~⑦ 发布顺序**。
