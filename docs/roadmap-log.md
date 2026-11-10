# Roadmap 执行记录

本文件是 [stable-roadmap.md](stable-roadmap.md) 的历史执行日志：每轮实现、验证、审查与实机测试的过程记录。
决策和当前待办以 stable-roadmap.md 为准，本文件只增不改，用于追溯"当时测了什么、结论是什么"。

---

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

---

# 历史决策归档（原 todo.md 的已完成条目）

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

## 0.23.10 录音收尾修复（2026-09-19）

背景与根因见 [stable-roadmap.md](stable-roadmap.md) P-0。本轮先把 0.23.9 的源码补提交（`aaf8002`，与 09-11 上传的 TestFlight 包一致：代码文件修改时间均早于 archive，二进制含 `TranscriptionAudioCoverage`、不含 "Time ratio"），文档整理单独提交（`85cf08f`）。

### 实际变更

- `IncrementalTranscriptionCoordinator`：按段记录 `[startFrame, endFrame)` 与结果；实时失败的段在 `stop()` 时原地重试 `finalRetryAttempts = 2` 次并按原位置拼回；Whisper 仍失败的段写入 `[m:ss–m:ss transcription unavailable]`、计入 `unrecoveredSliceCount`；只有 `.modelUnavailable/.audioUnavailable/.cancelled`/切片读取失败才设 `requiresFullTranscription`。
- `RecordingSession`：有未恢复段时 note 记为 failed（"N segment(s) failed after retry"），不再整篇排队；收尾剩余音频 ≥ 20 秒时通过 `RecordingFinalizationContinuation` 申请 `BGContinuedProcessingTask`，到期只释放、不取消工作。
- `ContinuedProcessingTask.swift`：系统驱动，每次用新 UUID 后缀注册（SDK：同一 ID 注册两次会杀进程；continued processing 允许启动后注册）；Info.plist 加 `BGTaskSchedulerPermittedIdentifiers`（`$(PRODUCT_BUNDLE_IDENTIFIER).finalizeRecording.*`）与 `processing`。
- `RecordingNotePhase`：列表与详情共用的状态判定，停止后（duration > 0）一律为 finalizing。转录中隐藏 Re-transcribe。
- `ModelManager.computeOptions`：`melCompute = .cpuOnly`（WhisperKit 默认 `.cpuAndGPU`）；Silero VAD 由 `.all` 改为 `.cpuAndNeuralEngine`。

### 验证

- Mac Catalyst 单元测试：266 tests / 32 suites 通过（含真录音回放）。
- iPhone 17 模拟器：单元 + UI 全量通过，新增 UI 测试 `testStoppedRecordingWithLiveTextShowsFinalizingNotRecording`。
- generic iOS 真机目标 Release 编译通过（`BGContinuedProcessingTask` 分支只在真机目标编译）。
- 真录音回放（09-17 会议，303 秒，Mac + `openai_whisper-small`）：三种情形（正常 / 注入 3 段实时失败 / 实时全部失败）均未触发整篇重转，行数一致；措辞差异来自 Whisper 温度回退采样（正常那份里还有 "Thank you for watching. Please subscribe" 幻觉）。有失败原因记录的 9 次运行中 4 次出现 `repetitive output`，都在结尾道别段 4:38–5:04，重试后要么补上、要么标成缺口。单次回放 24–52 秒。
- 未做：真机锁屏录音、`BGContinuedProcessingTask` 是否真的被系统批准、手机上 large-v3-turbo 的表现。

## 0.23.10 (2) 音频会话移出主线程（2026-09-19）

- 起因：真机调试时 Xcode 线程性能检查报 `AudioRecordingService.swift:523` 的 `setActive(true)` 有卡死风险；另有编译警告 `AVAudioPlayerDelegate` 上的 `@preconcurrency` 无效（新 SDK 已把该协议标为 `NS_SWIFT_UI_ACTOR`）。
- 建议的异步 `activate(options:completionHandler:)` 在 iOS 上要 27.0，工程最低 17.6，所以改为 `AudioSessionActivation`：一个串行队列执行所有 `setCategory`/`setActive`，激活用 `perform` 等待，停用用 `enqueue` 不等待；同一队列保证停用不会晚于后来的激活执行。
- `AudioRecordingService.startRecording()` 改为 `async`；预热用令牌防止被开始录音取代后再改状态。`AudioPlayerService.play()` 用请求令牌，激活期间暂停/停止/换选择则不再开始播放。
- 恢复录音在引擎被打断后的重新激活仍是同步（锁屏控件需要立即得到结果，且只在前台可用）。
- 验证：Mac Catalyst 单元测试 268 通过（新增 `AudioSessionActivationTests`：队列不在主线程、先停用后激活的顺序、错误回传）；iPhone 17 模拟器单元 268 + UI 22 通过。

## Codex 审查 `aaf8002 → 3cb903d` 后的取舍（2026-09-20）

Codex 提了 3 条，讨论后只修第 1 条，另两条有意不修：

1. **修**：停止时漏算正在转录的分片。`lastSegmentEndFrame` 在分片开始处理时就推进，分片转完才进 `slices`，`remainingAudioSeconds` 两头都没算它。例：29 秒分片在转，第 31 秒停止，剩余量算成 2 秒，低于 20 秒门槛，不申请 `BGContinuedProcessingTask`。改为记录在途分片并计入；门槛与转录、重试、取消、任务生命周期不变。新增两个测试（协调器 31 秒 vs 2 秒；停止时发出申请），去掉修复时两者都失败、恢复后通过。
2. **不修**：转录留有缺口时，系统进度任务仍报 `success: true`。只影响锁屏进度条最后显示成功还是失败；缺口已在正文标出、note 标为 failed，为结尾几秒的缺口在系统层报失败反而误导。
3. **不修**：播放在等会话激活时被切走，激活返回后会话没被释放。窗口只有激活耗时（毫秒到几十毫秒），后果是播放会话多占到下一次停用或开始录音；要修得在共享会话状态上加计数，写错的后果（点播放没声音）比原问题大。这个窗口是 0.23.10 (2) 把激活挪到后台队列时引入的。

验证：Mac Catalyst 单元测试 270 通过；iPhone 17 模拟器单元测试 270 通过。

## 0.23.10 (4) 手动重转录后台支持（2026-09-20）

- 用户确认旧版手动 Re-transcribe 锁屏后通常不能继续完成，本轮直接修复，不再要求复测旧问题。
- 显式保存音频转录/Resume 独立申请 iOS 26 continued-processing task，实时报告已完成分段进度；录音实时转录与收尾类保持不变。
- 申请被拒时前台仍可运行，进入后台安全暂停；过期取消当前解码，保留已完成分段和旧正文，回前台等待旧解码退出后恢复。未完成的当前分段需重新处理；短音频按原单次路径重跑。
- 用户主动取消不自动恢复；系统暂停状态提供 Resume 按钮。GPU 配置明确降级前台，按实际已加载配置判断；Catalyst 不应用 iOS 挂起限制。
- 修复重复前台激活提前结束 working-copy assertion 的竞争，以及显式本机恢复被 origin-device 五分钟等待挡住的问题。
- 新增 9 项回归。首个 request(force:) 后台申请测试在旧行为下失败（submissions 0 / completions 空），实现后通过。定向 107 tests / 3 suites；最终 Mac Catalyst 279 tests / 33 suites；iPhone 17 / iOS 26.2 同样 279 tests / 33 suites，加 22 项 UI 测试，全部通过。
- 主代理检查改动并完成独立任务内只读审查，无阻断性发现。已查看 UI 测试的取消后保留旧稿、分段预览截图；这些是夹具，不是后台系统授权或真实 ASR 的证据。
- iOS Release `ARCHIVE SUCCEEDED`；archive/app/widget 均为 0.23.10 (4)。正常钥匙串环境 `codesign --verify --deep --strict` 通过。沙箱内信任链校验报 `CSSMERR_TP_NOT_TRUSTED`，正常环境复验通过。Release 仅有既有 verbose=false 条件表达式的不可达分支警告。
- Archive：`/Users/tao/Library/Developer/Xcode/Archives/2026-09-20/Voicely 0.23.10 (4).xcarchive`。日志、截图及源码校验值：`/tmp/voicely-retranscribe-02310-4/`；构建前后核心源码 SHA-256 一致，`git diff --check` 通过。
- 真实 iPhone 锁屏期间是否完成仍待此包验收；进程终止后的恢复继续走原 pending/checkpoint 路径，本次后台任务所有权不跨进程持久化。未 commit、push 或上传 TestFlight；用户仅要求实现与 archive。

验证命令：

```sh
xcodebuild -scheme Voicely -destination 'platform=macOS,variant=Mac Catalyst' -parallel-testing-enabled NO -only-testing:VoicelyTests test
xcodebuild -scheme Voicely -destination 'platform=iOS Simulator,id=91A95B97-1254-429D-ADE2-D3375DDDD228' -parallel-testing-enabled NO test
xcodebuild -scheme Voicely -configuration Release -destination 'generic/platform=iOS' -archivePath '/Users/tao/Library/Developer/Xcode/Archives/2026-09-20/Voicely 0.23.10 (4).xcarchive' archive
codesign --verify --deep --strict --verbose=2 '/Users/tao/Library/Developer/Xcode/Archives/2026-09-20/Voicely 0.23.10 (4).xcarchive/Products/Applications/Voicely.app'
```

## 0.23.11 (1) prompt 回声与收尾修复（2026-09-21）

用户 0.23.10 (3) TestFlight 真机报告：长录音实时转录正常，停止后 "Finalizing" 迟迟不完成，锁屏后系统弹 "Finalization failed"；重转录报 63 分钟 22 段、40 多分钟 9 段 `failed after retry`。用户确认自定义 prompt 非空，并同意幻觉与 prompt 相关，但明确**不接受清空 prompt 作为解决方案**。

定位（读代码 + git history，未做真机复现）：

- "Finalizing" 状态、收尾重试、continued-processing task、"N segment(s) failed after retry" 的实时版本，全部由 0.23.10 `b8c8e91` 引入；0.23.9 及更早的 `stop()` 只刷尾巴，所以从未出现这个状态。分段失败本身不是它造成的——重转录路径的同名信息可追到 6 月 `54463ee`。
- 回退 `b8c8e91` 会回到"一段失败就整篇重来"，对 63 分钟录音严格更差，已排除。
- 失败分片的可疑来源是自定义 prompt 被 prefill 进每个 ~29 秒分片：安静分片上 Whisper 吐回 prompt 并复读，压缩比 > 8.0 判 `repetitive output`。11%–17% 的稳定比例支持这个解释，但**未经真机日志实锤**——Release 构建的 `debugLog` 是 `#if DEBUG`，且分段路径当时只保留失败计数、丢掉 diagnostic。

改动：

- `transcribeWithWhisper`：prompt 的失败模式下沉到解码器。首遍判定为 prompt 回声（归一化后抠掉 prompt 剩 ≤2 字符）或复读时，去掉 `promptTokens` 再解一遍；第二遍可用即采用，仍复读才 `repetitive output`，两遍都无可懂内容则 `noSpeech`。
- `IncrementalTranscriptionCoordinator.finalRetryAttempts` 2 → 1。
- `SegmentFailureRange` 增加可选 `reason`（旧 sidecar 仍可解码）；`SegmentedAudioTranscriber.failureSummary(for:)` 按原因分组计数，实时路径和重转录路径共用。
- `RecordingSession.recoverInterruptedFinalizations(in:)`，在 `setupServices` 调用：清理被杀在收尾中途、`isTranscribing` 残留为 true 的 note，保留已有文字并标记收尾被中断。

一处**没有**改：重转录部分失败时保留旧稿、把新结果存成 retained attempt。最初误判为"丢弃一小时好文字"并改掉，三个既有测试（`reTranscribePartialSuccessKeepsCompleteOriginal` 等）挡住了——新文字其实存进了 retained attempts 并在详情页可见。已回退该改动，并补一条测试固定这个行为。

验证：新增 4 个测试文件共 16 项（prompt 回声分类、失败原因汇总、旧 sidecar 兼容、收尾中断回收、重转录保留旧稿）。Mac Catalyst 297 tests / 37 suites 通过；iPhone 17 / iOS 26.2 模拟器 297 tests / 37 suites 通过（首两次失败是模拟器问题：`test runner hung before establishing connection`、诊断收集 600 秒超时、`immediateStopIsIgnoredOnFreshRecording` 在 1.0 秒防误停窗口上的负载相关 flake；`simctl shutdown all` 后重跑 24.6 秒全绿）。iOS Simulator 与 Mac Catalyst Debug 构建均成功。

未做：未 commit、未 archive、未上传 TestFlight。prompt 回声那条路径需要真实模型才能端到端验证，当前只有分类函数的单元测试。

验证命令：

```sh
xcodebuild -scheme Voicely -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:VoicelyTests test
xcodebuild -scheme Voicely -destination 'platform=iOS Simulator,id=91A95B97-1254-429D-ADE2-D3375DDDD228' -parallel-testing-enabled NO -only-testing:VoicelyTests test
```

## 0.23.11 (1) 后台任务停滞判定（2026-09-21，续）

0.23.10 (4) 已由用户上传 TestFlight 并装机（设备日志 appstored 记录确认 `version: 0.23.10 bundleVersion: 4`）。锁屏重转 20 多分钟录音，锁屏进度约 4% 时弹 "Transcription failed"。

取证：用户执行 `sudo log collect --device-udid 00008150-001924623CB9401C --last 3h`（`--last 30m` 那份没覆盖测试时间）。窗口内 5 个 `finalizeRecording.*` continued-processing 任务：

- 11:13:52、11:15:20、12:11:42 三次：submit 后立即 launch，随后 dasd `Task has not reported progress within expected cadence, marking stalled`（距上次更新 31.6–41.2 秒）→ `Activity Progress Policy … tracker.health == 2` → `AMNP` → `Suspending` → app 收到 expiration → `complete with success: 0`。三次分别在启动后 83 秒、54 秒、122 秒被收。
- 11:28:06：22 秒后 `CANCELED`；12:21:02：2 秒后 app 自己 `complete with success: 0`。这两次原因日志里看不出（app 的 `print` 不进系统日志），可能是用户在系统界面取消或回前台后的正常收尾，未追。

根因见 stable-roadmap P-0c：WhisperKit `TranscribeTask` 只在窗口结束时写 `progress.completedUnitCount`，单窗口分片解码期间进度恒为 0。

改动：`TranscriptionService.decodedWindowFraction` / `singleWindowSeconds`，解码回调里取 `max(WhisperKit 进度, 时间戳进度)`；`SegmentedAudioTranscriber.reportSegmentProgress`（单调前进）；`IncrementalTranscriptionCoordinator.reportSliceProgress` + `finalizationProgress` 计入解码中分片；`finishSavedContinuation` 成功判定改为"完成且有正文"。

验证：新增 `ContinuedProcessingProgressTests` 9 项。Mac Catalyst 306 tests / 38 suites 通过；iPhone 17 模拟器（`-parallel-testing-enabled NO`）306 tests / 38 suites 通过。时间戳进度能否让 dasd 满意只能真机验证。

提交：工作区里的三批改动拆成三个提交。`6daf989` 是 0.23.10 (4) 原样——用 `/tmp/voicely-retranscribe-02310-4/source.patch` 还原，7 个源码文件的 SHA-256 与 archive 时记录一致，Mac Catalyst 279 tests / 33 suites，与当时记录相同；`3e1dd7f` 是 P-0b（297 / 37）；P-0c 为其后一个提交（306 / 38）。拆分后的最终工作区与拆分前逐字节一致。未 archive。

## 0.23.11 (2) 重解期间的解码心跳（2026-09-21）

用户装 0.23.11 (1)（设备日志 19:43:52 `bundleShortVersion = 0.23.11; bundleVersion = 1`），锁屏重转仍被收走。`sudo log collect --last 1h`：

- 19:58:00 与 20:39:13 两次任务，dasd 在启动后 +17 s / +21 s 收到更新，之后 86 s / 57 s 无更新 → `marking stalled` → 用户离开前台瞬间 `AMNP` → `Suspending` → expiration → `success: 0`，下一秒 app `running-suspended`。
- 两次停滞期间 app 均为 `running-active-Visible`（SpringBoard runningboard 记录），所以不是后台降速，是前台也有一分多钟没有可见进度。

Mac 端取证：笔记库（`~/Library/Containers/com.hellotaotao.Voicely/.../default.store`，已通过 CloudKit 同步手机笔记）显示这三条长录音都用 `openai_whisper-large-v3_turbo_954MB` / Neural Engine，速度 0.20× / 0.52× / 0.74× 实时。音频取自 iCloud 容器 `recording_1789885222.680101.m4a`（2602 s），`ffmpeg -t 600` 截前 10 分钟做重放输入（放在 test host 的 `tmp/voicely-replay/saved.m4a`，另有 `saved-model.txt`、`saved-prompt.txt`）。

测量（`SavedAudioReplayTests` + `transcribeWithWhisper` 里 DEBUG 下每次解码的 fallbacks/tokens/temperature/ratio/logprob 日志）见 stable-roadmap P-0d。门槛 2.0/2.4 对比用的临时开关已删除，生产仍为 2.0。

改动：`TranscriptionService.decodeWorkCounter`（WhisperKit 回调里每步 +1）；`DecodeWorkHeartbeat`；`ContinuedProcessingHandle.advanceForWork()`（系统实现 +1 unit，封顶 9 900）；`SavedTranscriptionContinuation` 1 s 心跳任务、`RecordingFinalizationContinuation` 在已有 500 ms 上报里检查。

验证：新增 3 项心跳测试；Mac Catalyst 310 tests / 39 suites（含 opt-in 真实模型重放）通过；iPhone 17 模拟器 310 tests / 39 suites 通过。真实模型重放：音频进度最长停顿 28.0 s，加心跳后系统可见最长停顿 0.7 s。重放输入已删除（它会让每次 Mac 单测多跑约 5 分钟），需要时按上面的命令重建。

版本 0.23.11 (2)。未 commit、未 archive。

### 0.23.11 (2) 心跳补救复审与修正（2026-09-21）

用户授权在既有未提交修复上继续修改，不提交、不 archive、不上传。

- 先将系统进度运算原样抽为 Foundation-only `ContinuedProcessingProgress`，新增回归确认旧实现到 9 900 后心跳无效，且 decoder 在输出验证/重试结束前已经对外报满。定向测试实际失败后实施修正。
- 系统进度记录新增解码工作时可扩展总量，保留收尾预算，取消固定 99% 停更；仅成功结束才达到 100%，结束后忽略迟到更新。每次更新结束后的比例前进；Foundation 的总量/完成量分两次写入，不声称每个中间 KVO 事件严格单调。
- `transcribeAudioOutcome` 在取消检查及输出验证之后才报完成，窗口/第一次 prompt pass 的结束不再直接表示片段完成；未改变分片长度、温度 fallback 数或识别质量阈值。
- 修正 `SavedAudioReplayTests`：通过真实 request/continuation 及共享的 Foundation 进度运算记录提交值，不再用 50 ms token 轮询冒充系统进度。旧记录的 0.7 s 仅为 token 活动采样推算，不能用作新实现/iOS 接受进度的证据。模型加载时间独立报告。
- Release 新增 `TranscriptionTiming` / `ContinuedProcessing` unified log，记录准备、VAD、首 token、各轮解码及任务生命周期/实际进度，不包含路径、prompt 或转录正文。无 token 的准备阶段尚不保证后台持续执行，先据新日志定位。
- 独立只读定向 review 未发现阻断问题，建议的完成后忽略更新/取消不报满回归已加入。
- 补测短音频路径发现完成后异步 onProgress 会把已清理的进度重新写成 1.0；回归先失败，再移除主线程内多余的 Task 排队，确保更新先于清理。
- 最终验证：Mac Catalyst 与 iPhone 17 / iOS 26.2 均运行 320 项，318 通过、0 失败、2 项 opt-in 真实录音重放因未配置输入而跳过。iOS 27 首轮 319 项运行通过；收尾复跑未进入测试，主动中止该 runner 后使用 iOS 26.2 串行复验最终源码，不将其记为断言失败。
- iOS Release `CODE_SIGNING_ALLOWED=NO build` 成功，产物版本 0.23.11 (2)；`git diff --check` 通过。无 archive、签名分发、commit 或上传。记录和测试日志位于 `/tmp/voicely-heartbeat-followup/`。真实 iPhone 锁屏及新版本真实录音重放仍待验。

### 0.23.11 (2) 手动重转真机反馈（2026-09-22）

用户确认测试的是已安装的 TestFlight 0.23.11 (2)，通过点击 Re-transcribe 启动；锁屏状态下进度已持续推进至 38%。这是手动路径的阶段性真机证据，最终完成及正文持久化尚未确认。自动恢复修复没有 archive 或发布，不属于本次真机验证范围。

### 自动恢复 saved-audio 后台任务补漏（2026-09-22，未发布）

用户授权修复 P-0e，保留既有未提交修改，不改版本、不 commit、不 archive、不上传。

- 设备证据：`voicely-bg-2h.logarchive` 确认安装 0.23.11 (2)。自动恢复后后台进程被挂起，22:39:19–23:13:39 约 34 分 20 秒没有前台执行；未发现 continued-processing 启动记录。首段文件准备 27 ms、首 token 0.62 s，此次现象不是准备阶段等待。
- 在 `transcribeClaimedNote` 实际执行入口登记恢复的 queued/claimed saved job，再走已有 `beginSavedContinuation`；若已在后台且无 grant，第二次暂停检查会在文件准备/解码前退出，保留 checkpoint 和旧正文。
- 已运行 saved job 再收到手动请求时，缺失 grant 可补申请，但不重启解码、不重置分段进度。排队任务继续去重，不提前为自动排队任务申请后台任务。录音/新导入独立入口不变。
- `ContinuedProcessing` Release 日志补齐注册/提交/接受/拒绝（error domain + code）、平台跳过、saved-job 入口、申请条件和暂停原因；不写路径或转录内容。
- RED：原实现跑 69 项定向测试，29 个预期断言失败，定位自动恢复未登记/未申请/未主动暂停。最小修复后 69 项通过；追加队列推进回归后最终 70 项定向测试通过。
- 回归包含 queued 与 claimed 自动恢复、获批/拒绝、后台开始前阻断文件准备、切后台后轮到下一任务、用户取消清理、重复请求不重置 checkpoint、实际 SegmentProgressStore checkpoint + fresh service 模拟重启恢复。
- Mac Catalyst 与 iPhone 17 / iOS 26.2 全套各 326 项：324 通过、2 项 opt-in 真实录音重放因未配置而跳过、0 失败。测试驱动和 decoder 注入不等于 iOS 真正批准后台执行。
- iOS Release `CODE_SIGNING_ALLOWED=NO build` 成功；`git diff --check` 通过。版本保持 0.23.11 (2)，未创建 archive 或上传新包。
- 用户要求暂不调用额度耗尽的 Claude Code；该轮外部独立审查未执行。已本地逐项核对改动和回归测试，不将本地检查表述为独立审查。
- 日志与本轮前置 diff 位于 `/tmp/voicely-auto-recovery-fix/`。真机待验：保留未完成任务 → 重启自动恢复 → 不点 Re-transcribe 直接锁屏，核对 grant/Live Activity 与 checkpoint 是否推进。

### 按功能拆分提交（2026-09-22）

用户后续明确授权将上述改动拆成两笔本地提交；不 push、不 archive、不上传。第一笔 `14a884c` 对应 build 2 的解码心跳/进度修复，包含生产实现、回归/重放测试、版本及文档；第二笔只增加自动恢复后台任务修复、对应回归和诊断日志。最终生产源码、配置和测试文件与拆分前逐字节一致；仅文档补记用户手动路径锁屏推进到 38% 的反馈及本次提交记录。自动恢复仍未发布、未真机验证。

拆分验证：两个提交点各自重跑全套 Mac Catalyst 测试，第一笔 320 项（318 通过、2 项 opt-in 跳过），最终状态 326 项（324 通过、2 项 opt-in 跳过），均 0 失败；`git diff --check` 通过。记录及拆分前备份位于 `/tmp/voicely-split-commits/`。本轮未重复 iOS 验证；最终源码对应上一轮已通过的 iOS 26.2 全套测试与 iOS Release 构建。

## 1.0.0 上架记录（2026-11-07 至 11-10）

2026-11-10 从 stable-roadmap.md 移来，原样保留。build 5 审核通过，2026-11-10 09:16（阿德莱德时间）公开上架。

### 上架 1.0 的顺序（2026-11-07 排定）

可能改代码的事都放在真机验收之前，这样验收用的包就是提交的包。每一步的细节在后面的"上传与提交前"和"发布前 iPhone 清单"里。

**第一步：拍板**（2026-11-07 已定）

1. 不上中国大陆，不办 ICP 备案：销售范围里去掉中国大陆。
2. 1.0 免费，以后改成一次性买断，不做订阅。免费期间没有收入，DSA 交易者身份按这个声明；改成买断时再更新。
3. 掐头去尾不进 1.0，上架后再做；剪开头几乎用不上，只做剪尾巴（见 2a）。
4. 支持页和隐私政策页放 `voicely.taotao.au/support`、`/privacy`（网站源码 `hellotaotao/Voicely-web`，推到 main 由 Vercel 自动部署）。原来的两页和首页是 Whisper 时代写的，2026-11-07 按现在的 app 重写并已上线（当天 curl 核对过线上内容，三页都不再提 Whisper）。

**第二步：冻结代码**

5. ✅ 设置里加 Acknowledgements 页（2026-11-07，`AcknowledgementsView.swift`）：设置页 About 最后一行进去，列出千问（注明 MLX 8-bit 和 CoreML 两个转换版本）、Parakeet（CC BY 4.0，注明 NVIDIA 原作和 FluidInference 的 CoreML 转换）、Silero VAD（MIT）、speech-swift、FluidAudio、MLX Swift、swift-transformers、Jinja、Swift Collections、Swift Numerics，点进每一项看作者、链接和许可全文（Apache 2.0 全文随包，`Voicely/Licenses/Apache-2.0.txt`）。许可在 Hugging Face 和 GitHub 上逐个核对过。单元测试通过；没在 app 里亲眼看过，因为 TestFlight 版正开着，Debug 版和它同一个 bundle id。
6. ✅ 在 iPad 模拟器上看一遍布局（2026-11-07，iPad Pro 13 寸模拟器 iOS 27，浅色和深色）。修了两处（`dff84cb`）：竖屏一打开只显示空的详情页，笔记列表和录音按钮收在左上角的侧栏按钮里，新用户找不到录音按钮，现在 iPad 一打开侧栏就显示（Mac 不变）；选中的笔记行里日期和预览在 iPad 侧栏变成白字，压在浅紫底上几乎看不见，现在用固定的文字颜色。引导页、列表、详情页和录音条的布局都正常。模拟器接硬件键盘时选中行外面有一圈方的焦点框，是系统的键盘焦点，iPad 不接键盘时不出现，没改。没看的：横屏、设置页和致谢页（模拟器的点按权限没拿到，只能看启动后的画面）。
7. ✅ Mac 上的小验证（2026-11-07，在 TestFlight 0.33.1 上做，这两块代码和 1.0.0 相同）：
   - 搜索跳转（2d）：在一条 40 分钟的英文会议里搜 "agent"（36 处），往下跳、往回跳，当前那处都停在吸顶播放器下方的页面中间，没被挡住。
   - 定时停止（③）：设 15 分钟开录，用真鼠标每隔 0.3 秒连点 4 次 "+5 min"，结束时间从 17:23 变成 17:43，4 次都生效。再用 "Change Stop Time…" 改成 4 分钟后，到点自动停止并保存（6 分 56 秒，房间里没人说话，标成 No speech），计时按钮回到无计时状态。第一次设计时系统弹出了通知授权，用户点了允许。
   - 没测：结束前提醒通知上的三个按钮。电脑操作工具截图时会把 Voicely 切到前台，而 app 在前台时本来就不弹这条提醒；按钮走的处理路径有单元测试覆盖，iPhone 锁屏时的提醒和按钮在发布前 iPhone 清单里。
   - 笔记库里留下一条测试录音 "Voice Note 17:08"（2026-11-07），会同步到其他设备，要删由用户删。
8. ✅ 版本号改成 1.0.0（`00306d6`），从这个提交的干净源码打 iOS 和 Mac 两个包（build 1），2026-11-07 并行传上 TestFlight：打包约 13 分钟，上传 iOS 26 分钟、Mac 26.5 分钟，没有遇到凭证失效。还没打 `v1.0.0` tag：验收要是改了代码，提交审核的会是 1.0.0 的下一个 build，等定下提交哪个包再打。
   - build 2（2026-11-07）：build 1 的日志里没有千问的加载时间，也没有内存，第 10、12 条在真机上量不出数字。build 2 加了 `Memory` 日志类别（`MemoryFootprint.swift`），千问加载完、卸载后、每转完一片（CoreML），都记下用时和内存（`footprintMB` 是当前占用，`peakMB` 是这次启动以来的最高值，iOS 按这个数判断是否杀掉 app）；Parakeet 原有的 `loaded` 和 `stretch` 两行也带上这两个数。验收时按步骤正常用，最后 `sudo log collect --device` 抓一次日志，数字从里面读。从 `b66ffbe` 的干净源码打包，iOS 和 Mac 当天 19:28 都传上 TestFlight（打包 4.5 分钟，上传各约 26 分钟）。真机验收用这个包。
   - build 3（2026-11-08）：多了两处只影响显示的改动。文件夹栏：没有文件夹时只显示 All 和一个"+"，有了第一个文件夹才出现 No Folder（原来叫 Unfiled）；"+"始终只有一个，新建页写明最多 4 个；点已选中的文件夹打开编辑；删除有录音的文件夹先确认。设置页：选 English 时 Active Model 和 Speech Engine 显示 Parakeet，模型名不再折行。没有新增 `@Model` 字段，不用 deploy CloudKit Prod schema。从 `1baa59d` 的干净源码打包（各约 4.7 分钟）；第一次上传因 Xcode 账号凭证失效失败，重新登录后 09:41 重传，iOS 10:00、Mac 10:11 传完。真机验收改用这个包，build 2 加的内存日志它也有。

**第三步：在候选包上做 iPhone 真机验收**（逐条见"发布前 iPhone 清单"）

先测可能逼出代码修改的：

9. 去掉 `processing` 后台模式以后，iOS 26 锁屏续转系统还接不接受。
10. 千问 CoreML 的加载时间和峰值内存，决定 iPhone 要不要也改成用到时才加载。
11. 锁屏收尾、锁屏重转、自动恢复。60–90 分钟会议那一条不再专门测（2026-11-07 用户定）：用户最近的会议都用 iPhone 录，半小时左右，长录音这条路日常已经在跑。
12. Parakeet 第一次加载时锁屏能不能撑住；它和千问同时在内存里的峰值。
13. 语音门控：真实噪声不被编成句子，远处小声的"同意""No"不被丢掉。

再测只影响显示的：

14. 锁屏时的定时停止、录音中途被杀、麦克风授权三条路径、从旧 TestFlight 版本升级。
15. 详情页吸顶、点句跳转、文件夹长按拖动、Live Activity 和快捷指令。
16. 边测边拍 iPhone 和 iPad 的截图。

这一步改了代码就打新包，只重测受影响的那几项。

已进 build 3（2026-11-08，只影响显示）：设置页的 Active Model 卡片和 Speech Engine 一行跟着语言走，选 English 时显示 Parakeet TDT 0.6B v2 / Parakeet (CoreML)，以前不管选什么都显示千问；模型名在 iPhone 上不再折成两行。模拟器上两种语言都看过。文件夹栏的改动也在 build 3 里，单元测试通过、四种状态的渲染看过，点选中文件夹打开编辑和删除确认框还没在运行的 app 里点过，真机验收时顺带看。

2026-11-08 在 iPhone 17 Pro 上用 build 3 做了第一轮验收（下午 15:23–15:31 的设备日志，`sudo log collect` 抓的）：
- 第 9 项通过：去掉 `processing` 后台模式后，停止录音后锁屏、点重转后锁屏，系统都回 `submissionAccepted`。
- 锁屏时到点自动停止：用户实测通过。
- 第 10、12 项的数字：千问第一次加载（这个包装好后要为神经引擎编译）19.5 秒，加载完占用 1267 MB，边录边转时最高 1367 MB；编译过以后再加载 0.77 秒。Parakeet 第一次加载（同样要编译）14 秒。两个模型同时在内存里最高 1862 MB。iPhone 上千问要不要也改成用到时才加载，还差一个数：重新打开 app 后第一次加载要多久。
- 发现的问题：开着飞行模式重转一条音频只在 iCloud 里的笔记，app 干等约 90 秒下载，锁屏后台任务 31 秒没有进度就被系统收走，只显示 "task failed"；首页语言菜单当时只管下一次录音，设置页还是 English，重转就按 English 走，中文被 Parakeet 转成了乱码英文；重转确认框不管用哪个引擎都写千问。

build 4（2026-11-08，从 `ef50820` 的干净源码打包，各约 5 分钟；iOS 17:50、Mac 17:51 传完 TestFlight，并行上传各约 27 分钟）针对这些：
- 离线时音频只在 iCloud 里：不提交后台任务，笔记显示 "Waiting for internet"，联网后自动开始（`NetworkReachability.swift`）；等网络的时间不算进"5 分钟拿不到音频就停止自动重试"，进后台也不会被标成"被系统暂停"。
- 语言改成一个全局设置：首页录音条的菜单和设置页的 Speech Language 是同一个值，去掉了"只管下一次录音"；设置页说明缩成一句。
- 重转默认用这条笔记自己的语言（上次千问转的用 Auto Detect，全部是 Parakeet 转的用 English，没转过的按设置），确认框按钮写明 "Re-transcribe with Auto Detect" / "Re-transcribe in English"；笔记是 English 时多一个 "Re-transcribe with Auto Detect" 作为纠错的退路。请求那一刻就把语言定下来，存在本机（`RunLanguageStore.swift`），排队、改设置、app 被杀后恢复都不换语言。
- 日志新增 `Language` 类别：每次转写记一行 `languageDecision`（怎么触发的、什么语言、语言从哪来、先交给哪个引擎），English 下 Parakeet 没转出东西改交千问时记 `parakeetFallback`。
- English 下 Parakeet 没转出东西时先卸载它再加载千问；确定是静音的音频不再为它加载千问。
- 新版本或系统更新后提前编译两个模型（`ModelWarmUp.swift`）：每个模型记下上次成功加载时的 app 版本和系统版本，变了才做；打开 app 就开始（新用户就是在引导页里），只在前台、没录音、没转写、没有模型在加载时做，一次一个，Parakeet 加载完就卸载。设置是 Auto 时千问本来就在启动时加载，那次就算数。Parakeet 排队等引擎时也每 5 秒报一次进度，免得排在预热后面的锁屏任务被收走。
- 验证：Mac 上 505 个单元测试通过（新增语言固定、离线等待、Parakeet 先卸载、静音不加载千问的测试）；iPhone 模拟器上看过预热（千问启动时 10.4 秒加载后记为已预热，Parakeet 2.2 秒加载后卸载；同一版本重启后不再预热）和英文笔记的重转确认框。没在 Mac app 里实际点过，因为 Xcode 的 Debug 版和 TestFlight 版正开着。
- build 4 打包后，Codex（gpt-6-astra）审查补了一处，在 dev 上、不在 build 4 里：笔记文字已经从 CloudKit 同步过来、但 iCloud 连音频的占位文件都还没送到时，离线重转没有进入"等网络"，还是会干等、5 分钟后停止自动重试。改成 iCloud 路径上的音频只要本机读不到就算等网络。
- build 4 真机验收（2026-11-08 晚，iPhone 17 Pro，21:45–22:05 的设备日志）：
  - 预热通过：装好后第一次打开，千问编译 18.6 秒、Parakeet 编译 13.9 秒，用户在首页等着就做完了，最高占用 1290 MB。
  - 重转跟着笔记的语言走：当时设置是 English（build 3 留下的），两条千问转过的中文笔记重转都按 Auto Detect 走千问（`source=noteLanguage`），build 3 里转成乱码英文的问题不再出现。
  - 锁屏重转通过：两条中文笔记点重转后马上锁屏，锁屏期间都转完（`completed success=true`）。96 秒的录音 51 秒转完，105 秒的 34 秒转完；同样 15 秒的一片，前台 3.2–3.7 秒，锁屏后 6.7–14.2 秒。
  - 千问重新加载：编译过以后每次 0.76–0.79 秒，划掉 app 再打开后第一次也是 0.78 秒；卸载后占用从 1261 MB 降到约 90–100 MB。
  - 离线没测成：选的三条是 2026-09-08 的旧笔记，音频在 Mac 的 iCloud 文件夹里也不存在，前两条点的时候飞行模式还没开。三条都是一点就"拿不到音频"。日志里还看到：app 先向系统提交了后台任务，0.04 秒后又以失败结束，系统那边记的是失败。
  - 没做：英文笔记用 Parakeet 锁屏重转；乱码那条选 "with Auto Detect"（日志里没有 `source=userChoice`）。
- build 4 第二轮（同晚 23:04–23:13 的设备日志）：两条千问以前转过的英文笔记，重转时只给 Auto Detect，都是点了马上锁屏。
  - 4.5 分钟那条：千问 265 秒音频用 127 秒；接着 Parakeet 加载 1.07 秒（预热起作用了，11-01 锁屏首次加载要 100 秒），整段 270 秒交给 Parakeet，6 秒转完，等于千问白跑。
  - 40 分钟那条：千问锁屏时每秒处理 1.3–1.6 秒音频，中途点亮屏幕那 45 秒是 6–7 倍；转到 12 分钟时用户取消。按这个速度整条要 25 分钟以上，Parakeet 约 1 分钟。
  - 锁屏重转慢在 CPU：同一种 15 秒的片，检测语音那一步从前台 0.035 秒变成 0.33 秒，千问每一片慢 2–4 倍；Parakeet 主要算在神经引擎上，锁屏仍有 45 倍。下午 build 3 那条录音里，锁屏后边录边转的一片 15 秒音频 2.0 秒转完、检测语音 0.033 秒，没有变慢（只有一片，样本很少）。
  - 苹果声音分类器在锁屏重转时报错（`Sound classifier review failed`，SoundAnalysis Code=2），那一片按 Silero 的静音判断处理，和加这道复核之前一样。锁屏录音时能不能跑还没测。
- build 5（从 `6694203` 的干净源码打包，各约 4 分钟；2026-11-09 00:51 iOS 和 Mac 都传完 TestFlight，并行上传各约 23 分钟）的改动：
  - 音频连 iCloud 的占位文件都不在本机时，不再提交后台任务（以前提交后 0.04 秒就以失败结束，系统记成一次失败）；音频到了、开始转的那一刻再提交。日志 `savedContinuationSkipped reason=audioNotOnDevice`。
  - iPhone 上千问也改成用到时才加载，空闲 10 秒卸载，和 Mac 一样。依据：编译过以后加载 0.76–0.79 秒，重开 app 后第一次也是 0.78 秒，空闲时占着约 1.16 GB。
  - 重转的默认语言加看已有文字：文字读起来是英文的（没有非拉丁字母，被认成别的语言的句子按字数不超过 1%），不管上次是谁转的，主按钮都是 "Re-transcribe in English"，下面留 "with Auto Detect"。只要有一句就算外语太严：一条 2 小时的英文笔记就因为一句被误认的话被判出局；Mac 上那些只有拉丁字母的笔记里，误认的句子占 0.06–0.31%，真有外语段落的占 4% 以上。整条检查一小时的文字在 Mac 上约 0.5 秒，打开笔记详情时在后台算好并按笔记缓存。
  - Auto Detect 下千问转完、把英文段落交给 Parakeet 之前，先卸载千问（重转长录音、录音停止后的收尾、短录音一次转完，三处都是）。以前两个模型同时在内存里，23:07 那次最高 1760 MB；千问单独转写时最高约 1.47 GB，Parakeet 单独约 0.6 GB。前提条件：千问是用到时才加载的；这一刻没有千问在解码，也没有在加载（比如刚开始的新录音会预加载）；除了这条笔记自己，没有别的录音在进行。卸载过程中如果有解码要开始，会先等卸载完再重新加载，不会用到半卸载的模型。日志 `event=qwenReleasedForParakeet`。
  - 验证：Mac 上 510 个单元测试通过（含：没有别的录音时卸载，有别的录音或千问常驻时不卸载）；iPhone 模拟器上千问转的英文笔记详情页写 "Re-transcribe will use Parakeet TDT 0.6B v2"，确认框是 English 加 Auto 两个按钮。
  - 装上 build 5 后在真机上看：以前千问转的英文笔记，确认框主按钮是 "Re-transcribe in English"；锁屏时千问能在后台加载（`qwenLoaded`）；Auto 转英文录音时日志有 `qwenReleasedForParakeet`，峰值约 1.5 GB；锁屏开一次会，看边录边转每片要多久（目前只有一片样本：15 秒音频 2.0 秒）。
  - 声音分类器锁屏用不了的原因查清了：设备日志在报错前一行是 `Insufficient Permission (to submit GPU work from background)`。苹果内置的声音分类器在 iPhone 上有一部分在 GPU 上算，iOS 不让后台 app 用 GPU；分类器不让选算在哪个硬件上。iOS 26 的后台任务 GPU 权限按论坛反映目前只有 iPad 支持，而且锁屏录音用不上。1.0 不改，等锁屏会议的日志：每片的 `presence=silence` 和 `Sound classifier review failed` 已经够数出 Silero 判静音、没能复核的片有多少。
- 上架后再做：English 转完用千问只读语种标签检查是不是真的英文（2026-11-08 实测，苹果的文字语言识别认不出 Parakeet 把中文转成的乱码英文，一条 8.5 分钟的中文录音转出的 248 个词被判为英文）；录音中途切到 Auto 后在录音过程中就补转前半段（现在要等停止后才补，切换前每录 10 分钟停止后多等约 70–85 秒）。

**第四步：提交**

17. CloudKit Prod schema：部署前确认只在 Debug 跑过的 `alternateTranscriptData` 不会从 Development 带进 Prod。
18. 装一份干净的包，开飞行模式、关 iCloud，录一条能转出来。
19. App Store Connect：DSA 交易者声明（不声明就不能在欧盟上架；声明是交易者，地址、电话、邮箱会公开显示在商店页上）、App Privacy、年龄分级、出口合规、Mac 只限 Apple 芯片、价格和销售范围、审核说明、截图和文案、版权人。
20. 用户批准后点 Submit for Review。
21. 审核通过、商店页能打开以后，把 App Store 链接填进网站：`hellotaotao/Voicely-web` 的 `src/productMessaging.ts` 里的 `appStoreUrl`（现在是 `null`），推到 main 由 Vercel 自动部署。填之前网站上所有下载按钮都显示 "Coming soon to the App Store"。

