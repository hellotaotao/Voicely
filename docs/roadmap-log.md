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
