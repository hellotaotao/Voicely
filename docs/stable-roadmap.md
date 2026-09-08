# Voicely 稳定开发路线

## 当前决定

以 0.23.1 的实际使用体验为基线，小步演进现有程序；不重写，不整体合并 0.24.0 的未发布功能。每次只交付一个主要用户收益，在内部 TestFlight 实际使用后再推进下一项。

## R0：基线恢复

- 开发分支：`dev`。
- 起点：`6f3681baa2658b1bc774677e421546dee2f10c63`。
- 版本源：`Config/Version.xcconfig`，当前保留 `0.23.1 (1)` 作为重建标识；准备上传时使用新版本/构建号。
- 已上传 iOS 归档：2026-06-27 00:43 本地 archive，0.23.1 (1)，当地 00:49:35 上传 Apple 成功。
- archive tag 指向 `9304ef0`，但该提交仍标 0.23.0，说明归档时存在未提交修改。
- 本轮检查已上传 executable：包含 `DiagnosticsView`、`SegmentedAudioTranscriber`，不包含 `TappableTranscriptView`、`Qwen3`。字符串存在性仅作辅助证据，不是源码完整性证明。
- 采用归档后整理的版本配置提交 `6f3681b`，包含诊断和统一 app/widget 版本号，排除之后 28 个提交。
- 这是可追溯的功能重建基线，不宣称与旧安装包逐字节一致。

### 已保存的旧开发成果

- `old-dev` 保持在 `dea04f11eacb23e1a6a65e9a90f53ceba1a0afa8`，未重置。
- 未提交修复及 4 个未跟踪文件保存为 stash，并由 `backup/pre-r0-20260907` tag 固定引用，避免依赖变化的 stash 序号。
- 本地备份目录：`build/backups/pre-r0-20260907/`。
- `working-tree.tar.gz`：201 个已跟踪/未跟踪文件的完整内容；逐文件 SHA-256 已校验。
- `manifest.json`、`changes.patch`、`status.txt`、`head.txt`：备份清单和证据。
- `history.bundle`：旧 dev 和备份 tag 的完整 Git 历史，`git bundle verify` 通过。
- 旧 Qwen 的 ignored `.build` 缓存原地保留，以本地 `.git/info/exclude` 排除，不属于新基线源代码。

如需恢复旧开发状态，在工作区干净时使用以下命令；`--index` 恢复暂存状态，tag 对应 stash 的第三个 parent 保存未跟踪文件：

```sh
git switch old-dev
git stash apply --index backup/pre-r0-20260907
```

不要在稳定分支应用整个备份。后续只移植明确属于单一需求的实现与回归测试。

### R0 验收

- [x] 备份、校验、创建并切换稳定分支。
- [x] 核对发布归档与源码基线差异。
- [x] 原始基线单元测试和 iOS 构建通过。
- [x] 基线核心 UI 测试通过（原始 4 项失败，有限 accessibility 修复后通过）。
- [ ] 真实 iPhone 升级后旧音频与文字可读。
- [ ] 录音、暂停、停止、回放、基本转录、编辑、iCloud 验收。
- [ ] 核对 App Store Connect 版本/构建号后发布内部 TestFlight。

本阶段不移入 Qwen、词级时间轴、新抢救算法和大规模重构。发现基线问题，按证据单独列出，不自动把旧开发线的全部修复搬回来。

## 已确认发布顺序（2026-09-08）

用户已将旧 dev 重命名为 old-dev，将当前稳定分支重命名为 dev。本轮直接在 dev 完成①②，不提交、不推送、不上传。

| 阶段 | 范围 | 排除项 | 验收 |
| --- | --- | --- | --- |
| ① 收敛基线（本轮） | 0.23.1 加有限 Whisper 温度重试和逐段预览 | 点词同步、二分抢救、新性能卡片 | 新预览不覆盖旧完整正文；重复音频仍须真机 A/B |
| ② 关键可靠性（本轮） | 保存、转码失败、收尾、取消、队列及断点恢复 | 大范围架构重写 | 不丢音频；取消不跳过片段；恢复不删 checkpoint |
| ③ 定时停止与延长 | 手动开始，按时长或结束时刻自动停止；结束前提醒；随时延长 | 预约自动开始、重复计划、智能停止 | 真机前台、锁屏与切换 App 后按时停止并保存；延长后遵循新结束时间 |
| ④ 千问主力版本 | 中文及中英混说，完整下载/加载/长音频/恢复闭环 | 自动模型路由、逐词定位 | 同一 iPhone 的质量、速度与资源测试；通过后发布 |
| ⑤ Mac 专项 | 多声道转换、无信号提示 | 已撤回的 AVCaptureSession 实验 | 实际 USB 麦克风验证 |
| ⑥ 预约提醒录音 | 单次及重复本地通知、跳过某次；点击通知打开录音准备界面，用户点击开始；复用定时停止与延长 | 不做无人操作的自动开始；不含智能停止或服务器推送 | 真机验证通知权限、重复计划、取消及点击导航；打开通知不直接启动麦克风 |
| ⑦ 使用反馈驱动的增强 | 系统入口完善等 | 暂缓点词同步、Watch 与智能停止 | 一项做完整，发布后再做下一项 |

①②共同形成小范围发布候选。Whisper 小模型为兜底及英文快速识别候选；不恢复后来的 Large/Pro 目录改造，本轮不改变基线既有模型选择。普通编辑保留，但不维护文字与音频逐词对齐。

### 定时录音优先级调整（2026-09-08，用户确认）

定时停止直接解决会议结束后忘记停止、导致多余录音及后续转录和剪辑的问题，因此从原第五阶段提前，作为①②稳定版真机验收及内部 TestFlight 发布后的下一个独立功能版本，不等待千问或 Mac 专项。已在修复的 Mac 兼容性 bug 继续收尾，不因新顺序延后。

③的范围：

- 开始录音时可选择录音时长（例如 30、60 分钟，支持 35、41 分钟等自定义值），或指定结束时刻（例如 10:00）。
- 录音界面显示预计结束时间和剩余时间；结束前提醒，提前 3 分钟作为待设计确认的初始建议。
- 录音期间可一键延长（例如 10、15 分钟）、修改结束时间或立即停止。
- 无操作时按计划停止并保存，衔接现有转录流程。
- 验收不能只覆盖前台倒计时，必须包含真机锁屏、切换 App、延长和停止后的保存收尾。

⑥已根据用户后续确认收敛为“预约提醒录音”，不再将全自动后台启动作为本阶段研究或交付目标。流程为：

- 用户设置单次或重复提醒，例如每天或每个工作日 9:00；支持跳过某次。
- 使用 iOS 本地通知，由系统按计划提醒，不依赖服务器推送。
- 用户点击通知后打开 Voicely 的录音准备界面，带入该计划的结束时间或时长；此时不启动麦克风。
- 用户点击“开始录音”后才实际录制，并复用③的自动停止、结束前提醒及延长功能。
- 若按结束时刻设置，例如 10:00，晚于 9:00 开始仍以 10:00 为结束目标；若点击时计划已过期，先让用户确认新的时间，不沿用已过期目标。
- 验收通知授权状态、单次及重复提醒、取消与跳过、App 未运行时点击通知的导航，以及点击通知不会自动开始录音。提醒展示遵循系统通知设置，不承诺用户一定及时看到。

参考：[Apple 本地通知调度文档](https://developer.apple.com/library/archive/documentation/NetworkingInternet/Conceptual/RemoteNotificationsPG/SchedulingandHandlingLocalNotifications.html)。整体发布顺序不变，③先独立交付。

本文件为当前发布顺序的依据；`docs/app-store-release/widget-shortcuts-roadmap.md` 中的 Phase 编号属于早期系统入口专题规划，不代表当前整体发布顺序。

## 不单独扩大发布范围

- Whisper 模型目录先保持基线；新档位单独验证再加入。
- Mac 麦克风修复按平台处理，不与 iPhone 功能绑定。
- Live Activity/Shortcut 验收已有行为，不当成新功能重做。
- 性能问题先测量；优化限定于本版受影响路径。
- Watch、智能停止、摘要、更多模型、数据库替换暂不排期。

## 每版交付规则

1. 写清一个主要用户收益、范围、排除项、验收条件。
2. 在用户指定的 dev 上实现明确范围，保留 old-dev 作为参考。
3. 实现与相关回归测试一起完成，不做纯功能半成品合并。
4. 运行测试、真机验收、上传内部 TestFlight。
5. 用户实际使用；出现问题优先修复，不夹带新功能。
6. 当前版本验收通过后，再开始下一主要功能。

## 发布注意

基线 scheme 的 Archive pre-action 会自动执行 `git tag` 和 `git push`。因此当前 R0 验证只运行 build/test，不运行 archive。首次准备发布前应单独去除这一隐式远端副作用，改为明确、可追溯的发布步骤。

当前不推送任何分支、tag，不上传 TestFlight，不改动设备上的应用数据。

## R0 执行记录（2026-09-07 至 09-08）

- 原始重建基线 Mac Catalyst：150 tests / 22 suites 通过，`TEST SUCCEEDED`、exit 0；日志 `/tmp/voicely-r0-mac.log`。
- 原始重建基线 iPhone 17 / iOS 26.5：150 tests / 22 suites 通过；13 项 UI 测试中 4 项失败，均在 library 子控件定位断言；日志 `/tmp/voicely-r0-ios.log`。
- 有限移植：仅 `ContentView.swift` 的 library accessibility container 修复，以及 `VoicelyUITests.swift` 的对应定位调整，参考历史提交 `cb9d51d`。该提交里的导入/转录修复没有移植。
- 实现由主代理直接进行小范围移植；任务内只读交叉审查确认无新增功能，核心按钮、详情、路由和弹窗断言仍保留。
- 原始产品代码除上述一项 accessibility 标记外，保持 `6f3681b`；未修改数据模型、录音流程、引擎或依赖版本。
- UI 修复后：13 项 UI 测试全部通过，`TEST SUCCEEDED`、exit 0；日志 `/tmp/voicely-r0-ui-fixed.log`。该轮同时重新构建 iOS app。
- `git diff --check` 通过。没有执行 archive（避免基线 pre-action 自动推送），没有提交、推送或上传。
- R0 本地恢复与自动化验证完成；真实 iPhone 升级、长会议与 iCloud 验收未完成，当时尚未进入后续实现；本轮已获授权开始①②。

## ①② 实现记录（2026-09-08）

### 实际变更

- 有限 Whisper 温度回退（3 次、重复阈值 2.0）；没有恢复旧研究文档中的未经实测效果估计。
- 新增独立的分段预览，显示在转录进度下方；完整正文只在成功后替换。失败保留已有文字，但本次结果明确标失败。
- CAF 归调用方管理，等待 final flush 与持久化路径保存后才清理；M4A 转换失败回退 CAF，连持久化复制也失败则保留原始源。
- 停止与音频写入交接加锁；临时文件加 UUID；片段提取验证短读取，收尾按 29 秒窗口处理。
- 录音及收尾期间禁止删除和后台队列抢占；取消不提前释放解码占用，不跳过未完成片段。
- 取消后的工作副本和 checkpoint 保留；失败导入可手动重试，自动恢复不循环重跑已失败任务；导入恢复不清理普通录音的 checkpoint。
- 删除笔记阻止迟到识别结果回写；模型加载后触发导入恢复；补齐 UI 对无 audioFilePath 但有工作副本的导入重试入口。

### 审查与验证

- 当前任务内独立审查发现并修复：实时部分稿恢复失败仍被标为成功；导入重试 UI 的空路径 guard 阻断服务层恢复。
- 初次外部 Claude 审查被权限系统拦截；后续用户明确授权并完成订阅登录，已执行只读审查与定向修复，见下方记录。
- Mac Catalyst 完整单元：175 tests / 23 suites 通过，`TEST SUCCEEDED`；日志 `/tmp/voicely-phase12-mac-final.log`。
- 最终 iOS：175 tests / 23 suites + 15 项 UI 全部通过，`TEST SUCCEEDED`；日志 `/tmp/voicely-phase12-ios-verified.log`。重跑曾因测试运行器启动无输出而中止，重启本任务模拟器（未擦除数据）后全量通过。
- 预览与导入重试提示截图已检查：正文逐段显示、进行中标识及取消按钮可见。截图采用测试夹具，不代表真实 ASR 输出或速度。
- 报告 HTML 的解析、唯一锚点、导航和历史报告链接文件检查通过；浏览器安全策略拒绝自动打开 file URL，因此未完成网页渲染复核。

### 仍需真实设备验证

- 真实 iPhone 旧数据升级、录音/暂停/锁屏/中断/长会议、播放及 iCloud。
- Whisper 重复样本改前/改后质量、耗时与资源比较；本轮单测使用可控识别 stub，不证明识别率提升。
- 录音过程中强杀或转换完成前崩溃后自动关联临时 CAF，仍未实现；本轮保留源文件的正常停止/失败路径不等同于完整崩溃恢复。
- 用户取消的自动重启抑制是当前进程内状态；应用重新启动后，未完成任务仍进入原有恢复流程。

### 最终命令与状态

```sh
xcodebuild -scheme Voicely -destination 'platform=macOS,variant=Mac Catalyst' -parallel-testing-enabled NO -only-testing:VoicelyTests test
xcodebuild -scheme Voicely -destination 'platform=iOS Simulator,id=CABFC03E-857B-4351-9D07-3BB4BD3451D0' -parallel-testing-enabled NO test
git diff --check
```

本地实现与自动验证：PASS。25 项新增单元回归、2 项新增 UI 回归；未修改数据库 schema、引擎目录、依赖版本。主 agent 直接修改了报告及 ContentView/UI 测试接线，录音与转录实现由任务内 agent 分工并经独立审查。dev 保留未提交工作；old-dev 未改；未提交、推送、归档或上传。下一步是真实 iPhone 验收①②，再确定新版本与内部 TestFlight 发布。

## Claude 审查后的定向修复（2026-09-08）

- F-001：失败重转的新文字独立归档，在详情页可展开查看、选择与复制；旧正文保持不变。再次重试或后续成功不会删掉历史结果，显式删除笔记时清理。归档写入失败则拒绝重置 checkpoint。
- F-002：确认本地文件缺失后明确失败；iCloud 状态未知保留最多 300 秒的自动重试窗口，之后在下次处理时标记 unavailable，而不是误称文件丢失。手动重试开启新窗口。
- F-012：停止兜底创建笔记时补齐本机 origin，避免无谓等待 5 分钟。
- F-013：损坏 checkpoint 先按原始字节归档，再允许重试；真正写入失败仍保留原文件并停止重置。
- 修复父级 accessibility identifier 覆盖子控件的问题；增加保留文字查看/复制入口和横屏设置入口回归。三个旧测试改为验证实际 Settings 按钮，不再依赖已移除的根容器 ID。

验证：Mac Catalyst 185 项单元 / 23 suites；iPhone 17 模拟器 185 项单元 / 23 suites + 17 项 UI 全部通过，两平台 TEST SUCCEEDED。相对上一轮新增 10 项单元、2 项 UI。已查看保存结果的实际 UI 测试截图，使用测试夹具。最终日志位于 /tmp/voicely-review-fixes/mac-final.log 与 ios-verified.log。

外部 Claude Code 已获用户授权，通过订阅登录执行只读审查；复审结果见网页旁 claude-fixes-review-report.md。本次仅关闭上述定向缺陷，不宣称旧的完整审查全部通过。停止后后台执行、强杀恢复、真实 iPhone/iCloud 与真实 ASR 质量仍需独立验收。历史尝试目前仅本机保存，不同步；没有自动容量上限，跨设备删除后的历史清理仍待补充。

dev 保留未提交修改，old-dev 未改；没有 commit、push、archive 或 TestFlight 上传。

定向复审保留 F-014 小范围限制：旧排队时间可能令强制重转/接管首次读取失败后直接结束；数据不丢失，失败后手动重试会开启完整窗口。未将这次修复扩展为跨设备逐尝试状态重构。

## Mac 实机发布收尾（2026-09-08）

补齐有限 iOS 收尾后台预算、录音/收尾禁用删除、force/takeOver 刷新重试时间，以及实机复现的旧播放器资产残留。最终 Mac 191 单元 / 24 suites、iOS 191 单元 / 24 suites + 17 UI 通过。Mac 新录音停止后的播放器切换已实测通过；DJI 无线麦输入全静音，等待确认发射器状态，真实语音链路和 iPhone 后台验收仍未完成。第三轮 Claude 读取部分证据文件受限，按新 Skill 记为 incomplete；最终增量未独立复审。详细记录见网页旁 mac-release-check.md。未提交或上传。

## DJI 声道修复（2026-09-08）

用户授权单独移植 old-dev 2809420 的手动混单声道方案，不恢复录音通道实验。当前已实现，Mac/iOS各195项单元通过；硬件重新录音仍待验证。详情见网页旁 dji-recording-fix.md。此项是已知兼容性bugfix，不扩大为Mac录音架构重写。


## Hardware retest — 2026-09-08 14:31

本次扩展左右声道对称覆盖：仅左、仅右、双声道有信号，各覆盖 planar/interleaved 布局，并通过真实 AVAudioConverter 转为 16 kHz。连同单声道与空输入，共4个测试函数、14个用例；Mac Catalyst 和 iPhone 模拟器定向测试均 TEST SUCCEEDED。日志：/tmp/voicely-dji-hardware/mac.log、ios.log。本次没有重跑全量测试。

运行新构建的 Debug-maccatalyst/Voicely.app；系统默认输入为 DJI Wireless Mic Rx，USB、双声道、48 kHz。实际录音164.60秒，保存为16 kHz单声道文件；ffmpeg测得平均音量-25.9 dB、峰值-5.9 dB，区别于此前全静音样本的-91 dB。界面出现实时中文转录，停止后保留正文；播放器开始播放并推进至00:22，随后已暂停。录音已停止。

本次证明当前设备配置下录音、保存、转录输出及播放控制链路可工作。没有独立切换硬件左/右通道，左右对称性来自自动测试；未收到发射器状态确认，也未逐字核对语音或确认播放的固定英文句子被识别，因此不宣称识别准确率验收完成。停止瞬间仍短暂显示 Audio file unavailable，点击播放后消失。iPhone真机、长会议和锁屏/中断验收不在此次范围内。

## VAD and decoder acceptance — 2026-09-08

The original 81.86-second acceptance recording exposed a permissive VAD gate: a 19-second segment contained only four uncertain frames above 0.40 (peak 0.515), yet was admitted for transcription. Uncertain activity now requires 0.25 seconds of continuous evidence, carried across streaming reads; confirmed speech still passes immediately. Excessively repetitive Whisper output is rejected before successful persistence and follows the existing bounded retry/failure-preservation path.

The same local sample now skips the uncertain segment while preserving both speech segments. Two retranscriptions in the newly restarted Mac build retained both spoken sentences without repetitive garbage, with the original custom prompt restored. The user confirmed that the hesitation before “four” was actually spoken, not a recognition error. Mac Catalyst and iPhone simulator each passed 198 unit tests across 25 suites. Logs: /tmp/voicely-vad-full-mac.log and /tmp/voicely-vad-full-ios.log. UI tests were not rerun for this delta. The temporary private-audio diagnostic was removed from the repository.

The exact historical segment failure that originally triggered full retranscription remains unidentified. Fresh recording lifecycle acceptance after this delta, quiet-voice coverage, and iPhone device release gates remain separate from this sample-based regression check. The transient audio-unavailable UI message remains unresolved. No TestFlight upload or remote push was performed.


# Release stabilization follow-up

## Completed checks

The transient audio-unavailable cause was an optimistic M4A filename exposed before export existed. RecordingStopResult now exposes the existing CAF source until resolvedFilePath returns the durable export. Regression assertions failed before the fix. Mac and iPhone simulator each passed 199 unit tests /25 suites after the fix. Logs: /tmp/voicely-playback-ready-{red,mac,ios}.log.

A restarted Mac build recorded a new 22-second test note at 21:39. The observed post-stop UI no longer displayed Audio file unavailable. Playback started and advanced. This was a silence/background-noise sample, not a speech accuracy test. App exited after testing to stop playback. No iPhone physical-device acceptance or TestFlight upload occurred.

## Claude Opus round 2

Runtime claude-opus-5, requested high effort, subscription, read-only, exit0, no permission denials, structured schema validated. Review completed; reviewer verdict fail due unresolved important findings. F-002 confirmed fixed by text backstop8.0. F-001 native token2.0 and F-003 quiet/intermittent speech remain open; they are static risks, not reproduced physical-device failures. F-004 mono format pairing remains minor test gap. F-005 downgraded after acknowledging old gate already immediately admitted confirmed frames.

New minor findings: F-006 playing CAF during export can be interrupted when the durable path reloads the player; F-007 publishing temporary absolute path may expose a nonportable path through sync. These are not closed by the short local recording test. No third review invoked. Current changes are uncommitted and not pushed. Product release acceptance is not complete.

## Audio readiness correction — supersedes the CAF-first follow-up

Use transient RecordingSession readiness to defer playback until export resolves; persist the portable destination rather than exposing temporary PCM during normal conversion. Release readiness is separate from transcription final flush, so playback need not wait for transcription. Conversion failure still retains durable CAF or the only surviving source.

Mac: 200 tests / 25 suites passed. Live 51-second recording verified pause, resume, Preparing audio, final player, and playback progression to 23 seconds. No speech accuracy claim for this sample. Latest delta has primary verification, not a new Opus approval. Physical iPhone is currently unavailable; old-data upgrade, background/lock, meeting-length completeness and relevant iCloud checks remain release acceptance gates. No commit or upload.

## Acceptance scope update — user authorized

The user explicitly waived physical iPhone testing for this round and requested autonomous Mac testing plus iOS logic inspection. Do not request device connection again or keep physical testing as a blocking gate for this round. This waiver is not evidence that phone hardware or old-data upgrades passed.

Static iOS inspection: Info.plist declares background audio; iOS activates AVAudioSession .record; pause suspends PCM writes while retaining input IO; an interruption finalizes the existing note instead of pretending to continue; a finite UIKit background assertion covers finalization and ends on completion/expiration. Unit tests cover interruption finalization and assertion release. None proves actual lock-screen OS scheduling or device memory behavior. Model inference settings were not changed in this playback correction.

## Final verification for this delta

Mac unit tests: PASS, 200 tests / 25 suites; real recording/pause/resume/export/playback: PASS within the 51-second scope. iOS Simulator build: PASS (/tmp/voicely-readiness-ios-build.log). iOS unit execution: incomplete; both initial and explicit booted-device runs stalled at test startup with no test results, then were interrupted. The test host sample showed an idle application run loop and no XCTest image; this suggests a harness attachment issue, not an observed product assertion failure. Do not substitute the earlier 199-test result for this final delta. git diff --check passed. Phone testing waived explicitly by the user. Final delta remains uncommitted.
