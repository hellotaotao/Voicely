# Voicely 开发路线（唯一事实源）

> **这是本仓库唯一的 roadmap 与 To Do。** 原先散在 `todo.md`、`AGENTS.md` 的待办已全部合并到这里。
> 其他文档若与本文件冲突，一律以本文件为准。
> 历史执行/验证记录已剥离到 [roadmap-log.md](roadmap-log.md)，本文件只写"要做什么、做到哪一步"。
>
> 状态标记最后核对：**2026-09-13**，逐条按当前 `dev` 分支代码核实，不凭记忆。**2026-09-19** 补记 0.23.9 已提交、0.23.10 录音收尾修复（P-0）与 stash 回退（P-6）；**2026-09-20** 补记 build 4 手动重转录后台支持（P-0a）；**2026-09-21** 补记 0.23.11 prompt 回声与收尾修复（P-0b）、后台任务停滞判定（P-0c）、重解期间的解码心跳（P-0d）；**2026-09-22** 补记自动恢复漏接后台任务（P-0e）；**2026-10-13** 补记 0.23.12 收尾重试收窄（P-0g）与 Whisper/千问对比实测（P-0h）。

标记含义：✅ 已完成 · 🚧 进行中 · 🧪 代码就位、真机验收未做 · ⬜ 未开始 · ⚠️ 部分完成

---

## 一、当前状态一览

| 阶段 | 范围 | 状态 | 核实依据 |
| --- | --- | --- | --- |
| ① 收敛基线 | 0.23.1 + 有限 Whisper 温度重试 + 逐段预览 | ✅ | 已提交至 `dev`（`6cc7c75`…`575b9b4`） |
| ② 关键可靠性 | 保存、转码失败、收尾、取消、队列、断点恢复 | ✅ 实现<br>🧪 真机 | `7899dea`；Mac 实测通过，iPhone 真机本轮被明确豁免 |
| ③ **定时停止与延长** | 按时长/结束时刻自动停止，提前提醒，随时延长 | ⬜ **下一个** | 代码无 `autoStop`/`countdown` 相关实现 |
| ④ 千问唯一引擎 | 千问替换 Whisper，Whisper 整体移除 | ✅ 实现<br>🧪 真机 | 2026-10-17 已 fast-forward 合入 `dev`（`67d6c03`）；Mac 实测通过，iPhone 验收移到发布前专项（见 ④ 详情） |
| ⑤ Mac 专项 | 多声道转换 + 无信号提示 | ⚠️ | 手动 mixdown 已实现（`AudioRecordingService.swift:610`）；**录音中**实时无信号提示仍缺，只有录完后的静音提示 |
| ⑥ 预约提醒录音 | 本地通知提醒，点通知打开准备界面 | ⬜ | 无 `UNUserNotificationCenter` 调用 |
| ⑦ 反馈驱动的增强 | 系统入口完善等 | 🧪 | Live Activity / Shortcut / DeepLink 文件均已存在，真机验收未做 |

**版本现状（2026-09-19）**：0.23.9 已于 09-11 上传 TestFlight，当时是从未提交的工作区直接打包的，源码 09-19 补提交为 `aaf8002`。0.23.10 = 录音收尾修复（P-0），build 4 另含手动重转录后台支持（P-0a）。0.23.11 = prompt 回声与收尾修复（P-0b）+ 后台任务进度上报（P-0c）；build 2 加解码心跳（P-0d）。0.23.12（2026-10-13）= 收尾不再重解被拒分片（P-0g）+ 自动恢复走后台任务（P-0e）+ iOS 去掉 GPU 选项（P-0f），后两项此前已提交未发布。以上均待真机验收。0.23.8 起的版本都**不含** 0.23.5–0.23.7 的改动（见 P-6）。

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

### ④ 千问唯一引擎（2026-10-14 实现，2026-10-17 合入 `dev`）

2026-10-14 决定提前到 ③ 之前做，并且不做双引擎：千问 0.6B 是唯一引擎，Whisper/WhisperKit 整体移除。

- **后端**：Apple 芯片的 Mac 走 MLX（GPU），其余一律走 CoreML（CPU+神经引擎，锁屏可用）。选择逻辑在 `Qwen3Backend`，模型由 `Qwen3ASRModelStore` 独占。
- **切片**：两个后端都是单趟 30 s、分段 29 s、VAD 最早切点 15 s（`Qwen3SliceLimits`，依据见 P-0i、P-0j）。单元测试固定按 15 / 14 / 7 s 这组夹具跑。
- **模型**：MLX 约 1.0 GB（`mlx-community/Qwen3-ASR-0.6B-8bit`，P-0j；旧的 4-bit 在加载成功后自动删除），CoreML 约 0.95 GB（`aufklarer/Qwen3-ASR-CoreML` 的四个 mlmodelc + 分词器）。放在 Application Support/Qwen3ASR，不进备份。已下载的模型离线加载。
- **CoreML 解码**用的是 P-0h 验证过的 MLX-free 路径（`Qwen3CoreMLModel`），已补重复惩罚 1.15 和每片 `autoreleasepool`。
- **移除**：模型选择与模型列表页、自定义 prompt、计算单元选项、Benchmark 页、prompt 回声检测、温度重试相关逻辑。语言列表缩到千问支持的 30 种。旧 Whisper 模型文件在启动时清掉（`RetiredWhisperModels`）。
- **部署目标**：iOS 18.0 / macOS 15.0（包的要求）。构建需要 Xcode 的 Metal Toolchain 组件。

已验证（Mac）：310 个单元测试通过；`Qwen3RealModelTests` 用真实权重跑通 MLX 和 CoreML 两个后端；`RealRecordingReplayTests` 用真实模型跑通 5 分钟录音的边录边转与停止收尾（28 片，注入的失败全部原位恢复）；iOS 模拟器与真机架构 Release 均能编译。

2026-10-17 已合入 `dev`，之后在 `dev` 上开发。按 Mac 优先的开发规则，下面的 iPhone 项不再阻塞合并，改为发布前专项验收：

- **iPhone 真机**：前台和锁屏各录一条并转完。CoreML 路径从未在真机上跑过。
- **模型下载路径**没有实跑（测试用的是本机已有的权重）。首次启动会自动下载约 0.95 GB，不区分蜂窝网络。
- ~~完整流程的 29 s 实跑~~ 2026-10-15 已在 Mac 上完成（Debug，两个后端）：`VOICELY_SLICE_LIMITS=production`（加 `VOICELY_BACKEND=coreML` 可强制 iPhone 的后端）下跑 `RealRecordingReplayTests`（15 分钟中文辩论赛，边录边转加停止收尾）和 `SavedAudioReplayTests`（10 分钟英文会议，重新转录）。MLX 与 CoreML 都全部转出：40 / 41 片、无占位符，注入的 3 处和全部 40 处录音中失败都在收尾时原位补齐；重转 27 片、1 片静音。CoreML 重转时进度上报最长间隔 12.8 s（Debug），iPhone 上会更长，需真机确认不超过系统约 30 s 的容忍度。
- **蜂窝网络下载确认**（2026-10-15 已实现）：模型未下载且连接是蜂窝或个人热点时，自动下载改为弹窗询问；选"等 Wi-Fi"后不再追问，离开蜂窝网络时自动开始。
- **语言旧值迁移**（2026-10-15 已实现）：启动时把千问不支持的旧语言设置改回自动识别。
- **语言设置**（2026-10-15）：默认自动识别。实测中文夹英文的录音，自动与指定中文结果几乎相同、英文都保留；指定英文会让中文大段丢失或被译成英文。指定语言的选项移到设置页"Advanced"区；一旦指定，主界面录音按钮旁改为橙色显示"Language set to 某语言"，避免忘记。
- **重转显示与失败尝试**（2026-10-15）：重转中默认显示新转出的文字，可切回当前正文；正文只在成功后替换。失败尝试每条笔记只保留最近一次，入口放在"重新转录未完成"的提示下。
- **VAD 切点**（2026-10-17）：找不到 ≥0.35 s 的停顿时退到最深的短低谷，不再硬切；切点放在停顿中间（P-0l）。
- 词级时间戳仍然没有（千问只有分片级）。

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

### P-0d 🧪 同一窗口反复重解时进度停住，任务仍被收走（0.23.11 (2)）

0.23.11 (1) 真机：同样锁屏后被收走。设备日志里 dasd 这次**收到过**进度更新（启动后约 17–21 秒），随后 57–86 秒没有下一次，判停滞。两次都发生在 app **仍在前台**时（runningboard 记录一直是 `running-active-Visible`），用户一锁屏（NotVisible）1 秒内即被收走——前台期间 dasd 只记停滞不处置，离开前台才执行。

用那条录音（43 分钟辩论赛远场录音，large-v3 turbo，prompt `Claude Code`）的前 10 分钟在 Mac 上重放 saved-audio 路径（`SavedAudioReplayTests`，opt-in）：

- 31 次解码里 8–10 次把 WhisperKit 温度回退用满（一个窗口解 4 遍），吃掉约一半 token。原因主要是 **avgLogprob < -1.0**（远场、嘈杂但是真语音）和掌声/静音段烧几百 token 后输出为空；真复读只有 1–2 次。正常中文在温度 0 下压缩比 1.33–1.68，**不是** 2.0 门槛误判。
- 门槛 2.0 与 2.4 对比：速度 1.97–2.27× vs 1.96×、回退用满 8–10 vs 8，差异在同门槛两轮的随机波动之内，改门槛不是抓手。
- 只看音频进度，Mac 上最长停顿 17–29 秒；手机约慢 2.7 倍（手机实测 0.74× 实时）→ 45–78 秒，与 dasd 日志吻合。重解同一窗口时音频位置本来就不前进，按音频位置报进度原理上盖不住。

0.23.11 (2) 的改动：解码器每走一步（WhisperKit 每个 token 回调）计数加一；两类 continued-processing 任务每 0.5–1 秒检查一次，计数变了就把系统完成量推进 1 unit，锁屏副标题仍按音频位置。后续审查修正了 9 900 的硬上限：真实解码继续时，为新增工作动态扩展总量并保留 100 units 收尾预算；仅成功结束才报 100%。解码器没有 token 时不伪造心跳。

**重放证据更正**：此前“28.0 秒降至 0.7 秒”中的 0.7 秒来自 50 ms 轮询 token 活动的推算，没有经过生产 heartbeat 定时器、进度上限或 iOS 调度器，不能称系统可见的实测结果。重放现改为通过 `requestTranscription` 的真实 continuation 定时器及与系统共用的 `ContinuedProcessingProgress`，记录实际 Foundation 完成量/总量变化；模型加载时间另列，不混入运行中任务。iOS 接受这些更新仍须真机验收。

本次补救还将 decoder 的 100% 延迟到输出验证和必要重试完成之后，并新增 Release unified log：`TranscriptionTiming` 记录文件准备、VAD、首 token、每轮编码/回退时长，`ContinuedProcessing` 记录任务生命周期和节流后的实际进度。日志不包含音频路径、prompt 或转录正文。首 token 前的无回调长耗时本轮仅加测量，不宣称已解决。

补救自动验证：Mac Catalyst 与 iPhone 17 / iOS 26.2 各 318 项通过、2 项 opt-in 真实录音重放未配置而跳过、0 失败；iOS Release 无签名构建通过。仍未 archive/上传，不能替代下列真机验收。

2026-09-22 用户反馈：已发布的 TestFlight 0.23.11 (2)，手动点击 Re-transcribe 后锁屏进度推进到 38%；整次完成与正文保存仍待确认。本次未包含尚未发布的自动恢复修复。

真机验收：
1. 锁屏重转那条 43 分钟录音，看能撑多久；被收走就再导日志，看 dasd 给的理由是否变了（尤其是小幅完成量更新和尾段动态总量是否被接受——这点离线无法验证）。
2. 这条录音在手机上约 0.74× 实时，43 分钟要跑约 58 分钟。dasd 给任务标的 `UserInitiated, 900s` 是否为 15 分钟上限仍未确认；若是，长录音需解锁续跑（checkpoint 在）。
3. 速度本身的抓手是 `temperatureFallbackCount`（现为 3）：这条录音回退用满后 logprob 仍在 -1.15～-1.39，没变好。要不要降到 1，是质量与速度的取舍，待用户决定。

### P-0e 🧪 自动恢复绕过 saved-audio 后台任务（2026-09-22，随 0.23.12 发布）

0.23.11 (2) TestFlight 真机：打开 App 后自动恢复转录，锁屏无进度提示、无失败提示，但转录不推进。`voicely-bg-2h.logarchive` 确认 22:14:17 与 22:39:19 进入 `running-suspended-NotVisible`，后一段直到 23:13:39 回前台才恢复；没有 continued-processing 启动记录。用户确认很可能走的是自动恢复。

源码缺口：`processPendingTranscriptions` 可以恢复持久化 queued/claimed 任务，却没有登记内存中的 `savedTranscriptionNotes`；`transcribeClaimedNote` 只给已登记的任务申请后台执行。该路径也绕过了后台不可用时的主动暂停。

修复范围：在保存音频任务实际开始执行时统一登记并申请 continuation；后台才轮到的任务先暂停，回前台再申请。重复手动请求不得重置正在恢复的进度或重复启动解码。补充 Release 申请/拒绝/跳过原因日志，不含录音内容或路径。验证记录见 [roadmap-log.md](roadmap-log.md)。

真机验收：新包中保留一个未完成的重转任务，重启 App 触发自动恢复，不再点 Re-transcribe，直接锁屏；核对后台任务是否获批、锁屏期间 checkpoint 是否推进。自动化测试不能证明 iOS 实际批准或维持后台运行。

### P-0f 🧪 iOS 去掉 GPU 计算选项和 Benchmark 页（2026-09-27，随 0.23.12 发布）

iOS 在 App 进后台或锁屏后会中止 GPU 任务：CoreML 直接抛 `Insufficient Permission (to submit GPU work from background)`，不会自动退到 CPU；iOS 26 的后台 GPU entitlement 目前只支持 iPad。录音中的实时转录（`IncrementalTranscriptionCoordinator`）对此没有防护，选 GPU 时锁屏期间的分段会失败，停止后才重试。

改动：iOS/iPadOS 的 Encoder/Decoder Picker 只剩 CPU 和 Neural，Settings 不再显示 Run Benchmark（只剩 ANE 和 CPU 可比，没有意义）；Mac Catalyst 没有后台限制，GPU 和 Benchmark 都保留。计算单元本来就不持久化，启动总是默认 Neural，没有旧设置要迁移。`loadedModelSupportsBackgroundTranscription` 保留作兜底。

真机验收（可选）：本项目从未实测过"GPU + 锁屏"的实际表现，外部证据见 Apple Developer Forums thread 757715。

### P-0g 🧪 正文已完整却长时间停在 "Finalizing"（0.23.12）

TestFlight 0.23.11 (2) 用户反馈：录音能成功，但停止后 "Finalizing" 挂很久，而正文看起来已经完整。原因（代码推断，未拉设备日志）：停止时每个实时失败的分片都要重解一遍，而失败分片在收尾期间不留痕迹（占位符要等重试全部结束才插入），所以正文读着连贯、后台其实还在重跑。一片最坏是「带 prompt + 去 prompt」× 4 次温度，手机上 45–78 秒。

改动：停止时只重解 Whisper **没解过**的分片（模型还在加载、被取消、引擎抛错如锁屏时 GPU 被拒）。Whisper 解过但输出被判不可用的分片（`repetitive output` / `blank output`）不再重解，直接标占位符并带上原因；要补由用户点 Re-transcribe。`remainingAudioSeconds` 和 `finalizationProgress` 同步只算待重解的分片。

真机验收：录一段带停顿的长录音，停止后 Finalizing 应只持续尾段解码的时间；若出现占位符，记下失败原因分布。

同日追加（用户确认），把每个分片最坏的解码遍数从 16–24 降到 8（外层重试没了，温度回退保持 3）：

- `temperatureFallbackCount` 曾改为 1，经 Codex 质疑后做了 1 对 3 的配对回放（辩论赛录音，带 prompt 那遍），**已改回 3**：回退 1 次时 19 / 115 片明显更偏离参考文本（去 prompt 的输出），反过来只有 1 片；以英文为主的分片 21 对 3；耗时 882 s 对 1295 s。P-0d 里"回退用满后 logprob 仍差"只说明用满的那些没救回来，没覆盖第 2、3 次回退救回来的。
- 重转录路径（`SegmentedAudioTranscriber` 外层重试、单遍路径的自动重试）只对引擎抛错重试一次，被判不可用的输出不重试。失败文案相应从 "N segment(s) failed after retry" 改为 "N segment(s) failed"。

VAD 门控的现状：`NeuralSpeechAnalyzer` 对整个 ≤29 秒分片只做放行/跳过，任意一帧（36 ms）语音概率 ≥ 0.55，或 0.40 以上累计 0.25 秒，整片就原样送进 Whisper。

**VAD 门槛重放（2026-10-12，`VADGateReplayTests`，opt-in）**：那条 2602 秒辩论赛远场录音，Mac，large-v3 turbo 954MB，prompt `Claude Code`，`temperatureFallbackCount: 1`。按 app 的切法得 115 片，每片记 VAD 逐帧概率，再带 prompt、不带 prompt 各解一遍。原始数据在 test host 的 `tmp/voicely-replay/vad-report.jsonl`。

- **提高 VAD 门槛不是抓手。** 现门槛 115 片全部放行。要求 ≥0.55 的语音累计 1 秒只拦 4 片、3 秒拦 9 片，而被拦的里面有真话：第 2 片语音累计只有 0.07 秒，去 prompt 却转出一句完整的"…评委将这一票给了正方"。远场语音的 VAD 概率本来就低，门槛区分不开"没人说话"和"人离得远"。
- **问题在 prompt 本身。** 带 prompt 那遍有 10 片输出不可用（空、复读、乱码），其中 8 片去 prompt 能转出正文，5 片是 15–26 秒的满语音分片。另有 21 片带 prompt 的输出以英文为主（去 prompt 只有 1 片，且那片确实是 "Thank you"），例如把整段中文转成 "But in the Code of Law…"、"I'm sorry!" 连环复读。"Code" 一词在带 prompt 的输出里出现在 8 片，去 prompt 的输出里 0 片，全是 prompt 注入的。两遍文本相似度 ≥0.6 的只有 68 片（1579 秒），其余 47 片（1023 秒）有实质差异。
- 耗时：带 prompt 882 秒，去 prompt 639 秒；单片解码超过 10 秒的，带 prompt 26 片，去 prompt 4 片。

据此撤回了"prompt 回声直接判 `noSpeech`"：这条录音里判成回声的 2 片都不是静音，其中 1 片是 17 秒真话。回声和复读仍去 prompt 再解一遍。

Codex 审阅（gpt-6.1-sol，high，2026-10-13）另指出并已修：停止时重试仍失败的引擎错误分片被标成占位符后仍算"待重试"，使 `finalizationProgress` 到不了 1、`remainingAudioSeconds` 不归零；补了三个测试（引擎连续失败只重试一次、引擎在停止时恢复的会话层测试、重转录路径只多解一次）。它还指出 WhisperKit 0.16.0 的 `noSpeechProb` 写死为 0，调 `noSpeechThreshold` 无效。

未决：prompt 的用法。它现在被 prefill 进每个分片，这条录音里伤到的远多于帮到的（录音里没人说过 Claude Code）。候选：默认去 prompt 解码、只在用户明确需要时带；或带 prompt 的输出语言与去 prompt 的语言探测不一致时弃用。需用户定。

### P-0h 📊 Whisper 与千问对比实测（2026-10-12/13，Mac）

三条录音：辩论赛（中文远场，2602 s）、AI 会议（英文，3433 s）、会议 2（英文，2291 s，三条里最干净）。Whisper = large-v3 turbo 954MB，按 app 切片；千问 = Qwen3-ASR 0.6B，按 old-dev 的 14 s 切片规则。没有人工标准答案，质量来自指标和抽读。工具和脚本在 `docs/qwen-replay/`（依赖 old-dev 的 `Vendor/speech-swift`，用 `swift build --build-system native` 编译，MLX 的 metallib 需另备）。

| | 辩论赛 | AI 会议 | 会议 2 |
|---|---|---|---|
| Whisper 带 prompt / 不带（解码秒数） | 882 / 639 | 916 / 966 | 445 / 474 |
| 千问 MLX（GPU） | 96 s，27× 实时 | 97 s，36× | 79 s，29× |
| 千问 CoreML（仅 CPU+神经引擎） | 416 s，6.3× | 504 s，6.8× | 359 s，6.4× |
| Whisper 不带 prompt：空片 / 复读片 | 11 / 0 | 4 / 11 | 0 / 0 |
| 千问 MLX：空片 / 复读片 | 1 / 0 | 0 / 0 | 0 / 0 |
| 千问 CoreML 与 MLX 基本一致的切片 | 231 / 277 | 330 / 356 | 227 / 239 |

结论与坑：

- 录音干净时两个引擎质量接近（会议 2 上 Whisper 与千问 83% 分片一致）；录音差时 Whisper 出空片、复读、把带口音的英语判成波斯语/马来语，千问基本不出。千问自带标点。
- Whisper 的自定义 prompt 和千问的 `context` 都会凭空注入 "Claude Code"；提示词功能换引擎后要重新设计。
- **锁屏可用的是 CoreML 路径，速度约 6× 实时**，不再有 MLX 那 6–10 倍的优势，但最坏情况稳得多（会议上最慢切片 3.4 s）。峰值内存约 0.5 GB。
- vendored 包自带的 `transcribeWithoutMLX` 是坏的：把神经引擎返回的 Float16 当 Float32 读，输出乱码，且逐 token 预填只有 0.75× 实时。`docs/qwen-replay/Sources/QwenCoreML/main.swift` 里的 `transcribeMLXFree` 是可用的替代：批量预填、按 dtype 和 strides 读编码器输出，与原批量路径逐字一致。
- 每个切片必须包 `autoreleasepool`，否则约 200 个切片后 CoreML 抛 "Failed to allocate memory IOSurface" 崩溃（一小时会议必中）。
- CoreML 路径没有接重复惩罚：一段笑声会"哈"到 token 上限（单片 21 s）。需要在生成循环里补 repetition penalty 或 no-repeat n-gram。
- Mac 上让 CoreML 用 GPU 并不更快（2026-10-14，会议 2 前 30 片，神经引擎基线 6.5×）：`.cpuAndGPU` 只有 2.5× 且 30 片里 10 片文字与神经引擎不同，`.all` 5.3× 且输出逐字相同（系统仍选了神经引擎）。同一块 GPU 上 MLX 是 29×，所以差距来自 CoreML 逐 token 调用的开销，不是硬件。开关是 `COMPUTE_UNITS=all|cpuAndGPU|cpuOnly`。
- 未做：iPhone 真机（前台与锁屏）、词级时间戳、字错率。

### P-0i 📊 千问切片上限 14 s 对 29 s（2026-10-14，Mac）

同样三条录音。14 s 切点是把 app 的 29 s 切片按"7–14 s 内 VAD 概率最低处"再细分得到的，29 s 切点就是 app 原来的 Whisper 切片。CoreML 两组都带重复惩罚 1.15。

| | 会议 2 | 辩论赛 | AI 会议 |
|---|---|---|---|
| CoreML 14 s：速度 / 空片 / 最慢片 | 6.1× / 5 / 3.4 s | 6.5× / 8 / 3.1 s | 6.7× / 11 / 3.4 s |
| CoreML 29 s：速度 / 空片 / 最慢片 | 7.1× / 0 / 5.6 s | 7.6× / 0 / 5.3 s | 7.5× / 0 / 5.8 s |
| MLX 14 s：速度 / 最慢片 | 28.9× / 0.9 s | 27.0× / 1.1 s | 35.5× / 1.1 s |
| MLX 29 s（包的默认行为）：速度 / 最慢片 | 5.9× / 206 s | 33.5× / 1.3 s | 5.3× / 402 s |
| MLX 29 s（关掉长音频 n-gram 限制）：速度 / 最慢片 | 34.9× / 1.0 s | 36.3× / 1.3 s | 18.7× / 85 s |
| MLX 29 s 丢掉大半文字的切片 | 2（#62、#74） | 0 | 1（#76） |
| 切点落在 ≥0.7 s 停顿上：14 s → 29 s | 67% → 85% | 31% → 42% | 76% → 84% |

- **CoreML 用 29 s 全面更好**：更快、没有空片、切点更常落在真停顿上，文字量与 14 s 持平，没有复读和 token 上限截断。与 14 s 的输出按 29 s 片比较，相似度 ≥0.8 的占 100/100、99/115、149/153。
- **MLX 不能用 29 s**：超过 15 s 时包会自动加 no-repeat 3-gram，会出现单片解码几分钟、输出大小写错乱的乱文；关掉它之后仍有 3/368 片提前结束，只吐出一两句（同一片 CoreML 是完整的），还有一片 85 s。所以 MLX 保持 14 s。
- 重复惩罚在 CoreML 上生效：辩论赛原来的 2 个复读片（最慢 21 s）消失，速度基本不变。
- 没有人工标准答案，以上都是指标和抽读，不是字错率。

### P-0j 📊 Mac 的 MLX 换 8-bit 后可以用 29 s 切片（2026-10-15，Mac）

同样三条录音、P-0i 的切点。29 s 各组都关掉了包对 15 s 以上音频自动加的 no-repeat 3-gram，重复惩罚 1.15。每组只跑一遍，任务逐个运行。

| | 速度 | 丢掉大半文字的切片 | 复读切片 | 单片 >10 s | 峰值内存 |
|---|---|---|---|---|---|
| 4-bit，14 s | 35–38× | 0 | 0 | 0 | 1.2–1.4 GB（RSS，不含 GPU，见 P-0k） |
| 4-bit，29 s | 35–37× | 3 | 1 | 0 | 1.2–1.4 GB |
| 4-bit，29 s，无重复惩罚 | 35–37× | 2 | 5 | 0 | 1.2–1.3 GB |
| **8-bit，29 s** | **27–28×** | **0** | **0** | **0** | 1.5–1.7 GB |
| 8-bit，14 s | 26–29× | 0 | 0 | 0 | 1.6–1.7 GB |

- 丢字是 4-bit 量化的问题：P-0i 里出事的三片（会议 2 #62、#74，AI 会议 #76）8-bit 都完整，内容与 CoreML 一致。
- 卡死来自包自带的长音频 n-gram 限制，关掉即可；重复惩罚必须保留（去掉后辩论赛出现几十遍"现在，现在……"）。
- P-0i 里关掉 n-gram 后还有一片 85 s，这次重跑没有复现，原因不明。
- 代价：比 4-bit 慢约 25%，下载 1.0 GB（原 0.7 GB），内存多约 0.4 GB；仍是 CoreML 的约 4 倍。
- 测试数据与工具在 `~/Library/Caches/voicely-qwen-bench`（`run.sh`、`analyze.py`）。

### P-0k 🐛 MLX 缓存失控占满内存（2026-10-15，Mac）

Debug 版 app 转一条 64 分钟录音时，进程占了 13 GB，其中 12 GB 是 MLX 的 GPU 缓存，系统可用内存只剩 14%；当天早些时候整机死机一次，时间上与接连跑 MLX 测试吻合（推测，无直接证据）。原因是 speech-swift 对 0.6B 模型不限制 MLX 缓冲池，还把内存钉住（wired，上限为 GPU 建议工作集的 90%），只给 1.7B 设了 4 GB 上限。

用会议 2 和 AI 会议、8-bit、29 s 切片实测不同缓存上限（钉住只在第一行打开）：

| 缓存上限 | 速度 | 进程实际内存峰值 |
|---|---|---|
| 8 GB，钉住 | 24.5× | 9.7 GB |
| 4 GB | 27.0× | 5.6 GB |
| 2 GB | 26.4–27.7× | 3.5–3.7 GB |
| 1 GB | 23.6–23.9× | 2.5–2.6 GB |
| 512 MB | 24.6–26.0× | 2.0–2.1 GB |
| 256 MB | 25.1× | 1.7 GB |
| 0 | 24.4–25.2× | 1.5–1.6 GB |

速度不随上限变化（差异是波动），输出逐字相同，模型同时在用的内存始终是 1.9 GB。定为 0（不囤缓存，2026-10-15 由 512 MB 改来：切片长短不一，囤下的缓存很难再被复用，实测 0 与 512 MB 无差别）、取消钉住、卸载时清缓存（`Qwen3ASRDefaults.mlxCacheLimitBytes`）。旧表里 P-0j 的"峰值内存 1.2–1.7 GB"是不含 GPU 缓冲区的 RSS，不能当实际内存看。

另：Debug 构建下 MLX 只有约 5×（每 29 s 切片 5 s，GPU 利用率约 30%，CPU 单核跑满），Release 才是 25× 以上；判断速度要用 Release。

### P-0l 🧪 VAD 切点：找不到停顿不再硬切，切在停顿中间（2026-10-17，Mac）

原逻辑：在 15–29 s 窗口里找 ≥0.35 s、语音概率 ≤0.30 的停顿，切在**停顿末尾**（紧挨下一句开口）；一段都没有就在 29 s 处硬切。远场快语速的辩论赛里约 1/5 的窗口没有这么长的停顿，但每个窗口都有 0.1–0.3 s、概率接近 0 的短低谷。

改动（`bestNeuralSilenceCutCandidate`）：照旧优先 ≥0.35 s 的停顿；没有就退到最深的短低谷（深度为主、长度为辅）；两者都切在中点；只有整个窗口没有一帧低于 0.30 才落在批次末尾。

用三条录音按生产切片上限回放（`VADCutReplayTests`，跑的是 app 里的真实切点函数），旧/新：

| | 辩论赛（中文） | AI 会议 | 会议 2 |
|---|---|---|---|
| 切片数 | 113 / 126 | 152 / 154 | 101 / 106 |
| 切在批次末尾 | 28 / 0 | 8 / 0 | 6 / 0 |
| 切点后第一帧语音概率 >0.5（切在说话上） | 33 / 0 | 8 / 0 | 3 / 0 |
| 下一个词在切点后 50 ms 内开口（对齐模型的词起点） | 43 / 25 | 26 / 2 | 20 / 4 |
| 切点到下一个词开口，中位数 | 0.08 / 0.24 s | 0.32 / 0.96 s | 0.32 / 0.96 s |
| 接缝附近文字召回（对照以切点为中心重转的 16 s） | 0.914 / 0.920 | 0.913 / 0.902 | 0.933 / 0.946 |

- 切点位置明显改善；文字召回在这个方法的噪声范围内没有变化（参照本身也是另一遍 ASR，地板约 0.91），**文字层面的收益没测出来**。
- 辩论赛片数多了 11%。CoreML 编码器按固定 30 s 算，片越多越慢，估计 iPhone 上这条录音慢几个百分点，未实测。
- 对齐模型的词**结束**时间会盖住后面的停顿（例："那" 147.03–156.31 s），用它判断"切在词中间"不可信；词起点看起来可用。以后要做"对齐后切"得考虑这一点。
- 接缝处多余的句号这次没处理：中文切片 94% 以句号结尾，例如"我要成为一个。‖情绪稳定的人"。

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
