# Voicely 开发路线（唯一事实源）

> **这是本仓库唯一的 roadmap 与 To Do。** 原先散在 `todo.md`、`AGENTS.md` 的待办已全部合并到这里。
> 其他文档若与本文件冲突，一律以本文件为准。
> 历史执行/验证记录已剥离到 [roadmap-log.md](roadmap-log.md)，本文件只写"要做什么、做到哪一步"。
>
> 状态标记最后核对：**2026-09-13**，逐条按当前 `dev` 分支代码核实，不凭记忆。

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

**未提交的工作**：工作区有 13 个文件的改动（转录遥测按 note 隔离 + 分段路径接入遥测），对应下方待办 P-1，尚未 commit。

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

### P-1 🚧 转录指标：time ratio 与 speed 一直停在 "Measuring"

re-transcribe / 整文件转录时这两个值出不来；live transcription 正常。根因是分段路径没接遥测会话。

**当前工作区已在改**：`TranscriptionTelemetry` 增加 `processedAudioSeconds` 与区间合并（`TranscriptionAudioCoverage`），`SegmentedAudioTranscriber` 接入 `telemetrySession`，遥测快照按 `noteID` 隔离避免串台。**未提交。**

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
- 版本源：`Config/Version.xcconfig`（当前 `0.23.9 (1)`）。**只在这里改版本号**，app 与 widget 共用，不要在 Xcode target 里改。
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

- 基线 scheme 的 Archive pre-action 会自动执行 `git tag` 和 `git push`。首次准备发布前应单独去除这一隐式远端副作用，改为明确、可追溯的发布步骤。
- 上架材料在 [app-store-release/](app-store-release/)。注意 `release-checklist.md` 里写的 `MARKETING_VERSION = 0.15.3` 已过时，且版本源已迁至 `Config/Version.xcconfig`，以 xcconfig 为准。
- Voicely 从未正式上架，只发过 TestFlight，下次提交是首次公开发布而非更新。
- `app-store-release/widget-shortcuts-roadmap.md` 中的 Phase 编号属于早期系统入口专题规划，**不代表本文件的 ①~⑦ 发布顺序**。
