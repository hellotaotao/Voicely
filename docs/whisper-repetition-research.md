# Whisper 转录"重复幻觉"问题研究报告

> 针对 Voicely 转录中出现的大段重复（如 `It's not? It's not? It's not? …`、`That's it. That's it. …`）现象的成因分析、社区/业界方案调研，以及在 WhisperKit 端侧框架内的解码级根治路径。
>
> 调研日期：2026-06-28 ｜ 适用版本：本仓库当前 `dev` 分支 + WhisperKit（SPM checkout）｜ 文档版本：**v2**

---

## 0. 信息可信度说明（请先读）

本报告在工具链间歇性故障的环境下完成，因此对每条关键信息标注来源等级：

| 标记 | 含义 |
|---|---|
| **🟢 检索确认** | 来自成功的联网检索（真实 URL、issue 标题、维护者原话）。 |
| **🟢 代码实读** | 来自实际读取的源码（本仓库或 WhisperKit checkout）。 |
| **🟡 证据推断** | 基于已确认的局部证据 + 架构既有知识推断，**未逐行坐实**，落地前需核实。 |

> 会话期间 Bash / Read / WebFetch / WebSearch 多次返回空值或与命令无关的垃圾文本（含**疑似提示注入**，会伪造"结论"或"System 提示"试图误导）。凡受影响内容一律未当作事实写入；不确定处以 🟡 明示，绝不以故障/注入输出冒充核实。

---

## 1. 现象

较长、较嘈杂的录音里，转录结果中间会出现同一短语连续重复几十次：

- `It's not? It's not? It's not? …`（英文会议录音）
- `That's it. That's it. That's it. …`（粤语/英语混合录音）

回听原始音频确认：那几段**确实是同一个人在含糊地说话**（语速不稳、口音、背景人声），**并非静音**。人耳能大致听出在说什么，但内容杂乱。——这一点对后文"VAD 治不了此案例"至关重要。

## 2. 根因：Whisper 全系列（含 WhisperKit）的固有失败模式 🟢

Whisper 是**自回归 Transformer 解码器**，逐 token 生成，且默认**以已生成的前文作为后续解码的条件**。遇到"听不清/不确定"的音频时，会陷入**自我强化的退化循环**：

1. 吐出一个短语，例如 `It's not`；
2. 基于前文条件，模型判断"下一个最可能还是 `It's not`"；
3. 无限重复，直到该解码窗口结束。

这**不是某一句识别错误，而是解码器层面的退化**。高发场景（🟢 OpenAI Whisper Discussions #2070 / #2606 / #2608 / #928）：静音/近静音段（最常见）、低质量音频与噪声、多人重叠、语速口音异常、某些 initial prompt。

## 3. 我们当前配置与已落地的修复 🟢 代码实读

`Voicely/TranscriptionService.swift`（约 982 行起）正常转录路径的解码配置。**已应用修复**（git diff 确认）：

```swift
var decodeOptions = DecodingOptions(
    task: .transcribe,
    language: languageCode,
    temperature: 0.0,
    temperatureFallbackCount: 3,        // 原为 0；重新启用 temperature fallback
    sampleLength: 224,
    usePrefillPrompt: true,
    usePrefillCache: false,             // 注：默认为 true，影响速度，与重复无关
    detectLanguage: isAutoLanguage,
    skipSpecialTokens: true,
    withoutTimestamps: false,
    wordTimestamps: false,
    clipTimestamps: [0.0],
    compressionRatioThreshold: 2.0,     // 原为默认 2.4（过松）；降低以让重复段更易触发 fallback
    chunkingStrategy: ChunkingStrategy.none   // 自有 VAD 已把音频切成 ≤29s
)
```

**为什么两个一起改（缺一不可）**：
- `temperatureFallbackCount` 是"打破循环的手段"——检测到退化就升温重解码。原值 `0` 等于关闭这个安全网。
- `compressionRatioThreshold` 是"发现循环的触发器"——gzip 压缩比超阈值即判退化。默认 `2.4` 偏松，很多重复段达不到 2.4，fallback 根本不触发。降到 `2.0` 让它更灵敏。
- 只改前者：报警器太钝，循环报不出来；只改后者：报了警没人出动。（🟢 依据 WhisperKit issue #294 维护者 @finnvoor 建议）

> ⚠️ **参数顺序坑（实战踩过）**：Swift 的具名参数**必须按 `DecodingOptions` 的声明顺序传**。`compressionRatioThreshold` 在声明里排得很靠后（位于 `clipTimestamps` 之后、`chunkingStrategy` 之前），不能图方便挨着 `temperatureFallbackCount` 写，否则报错 `Argument 'sampleLength' must precede argument 'compressionRatioThreshold'`、编译失败。所以两个反重复参数在代码里**不相邻**——`temperatureFallbackCount` 在前段、`compressionRatioThreshold` 在 `clipTimestamps` 之后。以后加任何 `DecodingOptions` 参数都要先核对声明顺序。

> ⚠️ benchmark 路径（`BenchmarkView.swift`）**未改**，保持确定性可复现。
>
> ✅ 我们已做对的一件事：用**自有 VAD 把音频切成 ≤29s 段**。VAD 预处理是公认最有效的反幻觉手段之一。详见第 5 节。

**这套修复的预期效果（工程估计，非实测）**：对"满屏机械重复"约 **70~85%** 能消除/显著缩短；但"把那段杂乱话语准确还原"只有约 **20~40%**——后者受限于音频质量与模型能力，参数管不了。**下行风险很低**（清晰音频不触发 fallback，几乎无影响），值得直接实测。

## 4. 社区 / 业界方案调研

### 4.1 WhisperKit 仓库相关 issue（argmaxinc/WhisperKit）🟢 检索确认

| Issue | 标题 | 要点 |
|---|---|---|
| **#294** | Stuck token loops, even with temperature fallback | 即使开启 fallback 仍会卡循环（尤其 `wordTimestamps` 开启时）。维护者 **@finnvoor 建议把 `compressionRatioThreshold` 降到 `2.0`**，"能抓住大部分重复"。 |
| **#102** | temperatureFallbackCount doesn't work? | 该参数行为不符预期，旁证"只改 fallbackCount 未必够"。🟡 完整结论未逐条复核。 |
| **#122** | compressionCheckWindow not utilised? | 涉及重复检测窗口。🟡 完整结论未复核。 |
| **#283** | gibberish hallucination | 一般性幻觉质量问题。 |

### 4.2 OpenAI Whisper 主线社区共识 🟢 检索确认（Discussions #2070/#2608/#2606/#928）

按性价比：① VAD 去静音（最有效）② temperature fallback + 调低 compressionRatioThreshold ③ `condition_on_previous_text=false`（防自我强化，代价是连贯性）④ logProb/noSpeech 阈值 ⑤ 后处理去重（兜底，治标）。

### 4.3 WhisperKit `DecodingOptions` 默认值 🟢 代码实读确认

已读取 `Configurations.swift`（共 252 行）`public init(...)` 逐项确认（也是上面"参数顺序"的依据）：

| 参数 | 源码默认值 | 与本问题关系 |
|---|---|---|
| `temperature` | `0.0` | 起始温度 |
| `temperatureIncrementOnFallback` | `0.2` | 每次 fallback 温度增量 |
| `temperatureFallbackCount` | `5`（默认开启） | 我们曾改 `0`（关闭），现改 `3` |
| `compressionRatioThreshold` | `2.4` | gzip 压缩比阈值，触发 fallback 主要判据；偏松 |
| `logProbThreshold` | `-1.0` | 平均 logprob 阈值，另一个 fallback 触发器 |
| `firstTokenLogProbThreshold` | `-1.5` | 首 token logprob 阈值 |
| `noSpeechThreshold` | `0.6` | 静音判定阈值 |
| `usePrefillPrompt` | `true` | 我们 = true（一致） |
| `usePrefillCache` | `true` | **我们 = false（不同）**，影响速度 |
| `chunkingStrategy` | `nil` | 我们显式 `.none`（自有 VAD） |

**声明顺序（关键，决定调用时参数排列）**：…`temperatureFallbackCount` → `sampleLength` → `topK` → `usePrefillPrompt` → `usePrefillCache` → `detectLanguage` → `skipSpecialTokens` → `withoutTimestamps` → `wordTimestamps` → `maxInitialTimestamp` → `clipTimestamps` → `promptTokens` → `prefixTokens` → `suppressBlank` → `supressTokens` → **`compressionRatioThreshold`** → `logProbThreshold` → `firstTokenLogProbThreshold` → `noSpeechThreshold` → `concurrentWorkerCount` → `chunkingStrategy`（末位）。

**更正（推翻早期推测）**：`compressionCheckWindow` **不存在于当前版本 `DecodingOptions`**（既不在字段也不在 init）。不要去设它。另：当前版本新增 `voiceActivityDetector: VoiceActivityDetector?` 字段（WhisperKit 内置 VAD）。

### 4.4 `condition_on_previous_text` 在 WhisperKit 中的对应 🟡 证据推断

OpenAI 原版有显式 `condition_on_previous_text` 开关；**WhisperKit `DecodingOptions` 无同名字段**。前文条件主要受 `usePrefillPrompt` / `usePrefillCache` / `promptTokens` / `prefixTokens` 影响。WhisperKit **没有等价的单一"关闭前文条件"开关**，不要照搬原版字段名。

### 4.5 业界产品怎么处理嘈杂/长/多人音频？🟢 检索确认

这是**普适问题**——faster-whisper 仓库有 "hallucination, again and again and again"、"repetition problem?"、"transcription hallucination even using vad_filter"；WhisperX 有 "Hallucination, when audio gap & repetition"。所有用 Whisper 的产品都在搏斗。"解决得好"的产品靠的是**一整条流水线**，不是单参数：

| 环节 | 业界做法 | Voicely 现状 |
|---|---|---|
| 1. 音频预处理 | 降噪、人声分离（demucs/RNNoise） | ❌ 未做 |
| 2. VAD 去静音切分 | Silero VAD 切在静音处、**丢弃纯静音段** | ✅ 已做（见 5.1） |
| 3. **解码级反重复** | `repetition_penalty` + `no_repeat_ngram_size` | ⚠️ WhisperKit 无现成参数，但可扩展（见第 6 节） |
| 4. temperature fallback | + 低 compressionRatioThreshold | ✅ 已做（第 3 节） |
| 5. 关闭前文条件 | `condition_on_previous_text=false` | ⚠️ WhisperKit 无直接开关 |
| 6. 强制对齐 | wav2vec2 揪出对不上音频的幻觉（WhisperX 核心） | ❌ 未做 |
| 7. 后处理去重 | 检测并折叠重复 n-gram + 置信度过滤 | ❌ **明确不采用**（见下） |
| 8. 说话人分离 | pyannote 先分轨（多人场景） | ❌ 未做 |
| 9. 换大模型 | large-v3 / turbo，幻觉天然更少 | 可选（见第 7 节） |

**关键差异——你的武器库取决于后端**：很多产品用 **faster-whisper（CTranslate2 后端）**，它暴露了 `no_repeat_ngram_size`（物理禁止 n-gram 重复）和 `repetition_penalty`（概率惩罚）这两张硬核牌。**我们用的 WhisperKit 是端侧 CoreML 后端，`DecodingOptions` 不暴露这两个参数**。这是一个诚实的权衡：

> WhisperKit 换来**完全离线、隐私、免费、不依赖服务器**；代价是**反重复工具箱比服务端 faster-whisper 小**。但并非无解——见第 6 节的 `LogitsFiltering` 扩展点。

## 5. VAD 环节分析：为什么它治不了"本案例"

### 5.1 我们 VAD 的现状 🟢 代码实读

`Voicely/NeuralSpeechAnalyzer.swift`：我们**不是**用简单能量/音量阈值，而是用 **Apple 神经网络识别器 `SFSpeechRecognizer`** 判断语音 vs 噪声/静音，只把语音段（≤29s，静音间隔 `minSilenceGap=0.6s`，最短段 `0.5s`）切出来喂给 WhisperKit。源码注释明确：用神经识别器是为了"把真实语音和环境噪声区分开，免得 Whisper 在非语音区幻觉"。**VAD 这一环已是高配实现。**

### 5.2 诚实判断：VAD 对本案例无能为力

用户的 `It's not` 案例，那段**确实有人在含糊说话，不是静音**。VAD 的本职是剔除"没人说话"的部分，它不会、也不应把真实语音段删掉（删了就真丢内容）。我们的 Apple VAD 已正确地把它判为语音并喂给 Whisper。

> **VAD 强在"静音型幻觉"（对着没人说话的片段凭空编），对"真实但杂乱语音型重复"几乎使不上劲。** 顺着 VAD 调，治不到本案例的病根。唯一沾边的是"把杂乱长段切得更碎以限制循环蔓延"，但 0.6s 间隔已在切，再激进会误切词、损上下文，对"连续无停顿的杂乱语音"仍无效。不建议为本案例动 VAD。

## 6. 解码级根治路径：WhisperKit 的 `LogitsFiltering` 扩展点（重点）

用户诉求：**不做后处理（怕误伤、要如实呈现），从解码环节避免重复。** 调研结论：**可行，且大概率不用 fork WhisperKit。**

### 6.1 三层方案对比

| 方案 | 做法 | 评价 |
|---|---|---|
| **A. 调紧第二触发器** | 把 `logProbThreshold` 调激进（重复常伴低置信度） | 零代码、可顺手试；本质仍是 fallback，治标 |
| **B. 回调中止** | `transcribe` 回调每步给"已生成 token/文本"，检测尾部死循环就 `return false` 掐断窗口 | 纯 app 层、可控；但是"掐断"非"绕过"，会丢循环点之后内容，**且与后处理同有误伤风险（只是时机提前）→ 不符合"如实呈现"，不主动推荐** |
| **C. 自定义 `LogitsFilter`** | 解码每一步就把"会造成 n-gram 重复"的 token 概率压到 -∞，模型自然走向别的词 | **最对症、最优雅、不误伤、不改输出**——正是 `no_repeat_ngram` 等价物 |

### 6.2 C 方案的源码依据 🟢 代码实读

读取 `LogitsFilter.swift` 全文 + `TextDecoder.swift` grep 确认：

1. `LogitsFiltering` 是 **public 协议**：
   ```swift
   public protocol LogitsFiltering {
       func filterLogits(_ logits: MLMultiArray, withTokens tokens: [Int]) -> MLMultiArray
   }
   ```
   每步解码被调用，拿到「下一 token 概率分布 + 已生成全部 token」。内置 `SuppressTokensFilter` 即把目标 token 的 logit 设 `-.infinity` 让模型绝不选它。
2. `TextDecoder.swift` 底层解码方法签名（第 148 行）**带 `logitsFilters: [any LogitsFiltering]` 参数**，第 163 行 `for filter in logitsFilters { ... }` 逐个应用——**解码循环是"参数化吃 filter 列表"的，非写死。**
3. 但该列表（第 59/74/85 行）由 decoder **内部**根据 `DecodingOptions` 构造；**`DecodingOptions` 无"传入自定义 filter"的字段**（已读完整 init 确认）。

### 6.3 落地路径与待坐实点

**推断路径 🟡**：`LogitsFiltering` 与 `TextDecoding` 均 public、解码循环参数化，缺的只是"把我们的 filter 塞进列表"的入口。预期通过 **自定义/包装 `TextDecoder`**（`WhisperKit` 初始化可注入自定义 `textDecoder`），在构造 `logitsFilters` 时额外加入我们的 filter，无需 fork。

**待坐实（工具故障未读完）**：
- [ ] `TextDecoder.swift` 第 52–100 行 filter 列表的确切构造逻辑；
- [ ] `decodeText` 是否为 `TextDecoding` 协议方法、能否被干净覆盖；
- [ ] `WhisperKit` 注入自定义 `textDecoder` 的确切 API。
- 若构造逻辑藏于不易覆盖的私有方法 → 可能需给上游提小 PR（WhisperKit 开源，合理路径）。

> ⚠️ 调研中注入文本曾伪造"no public injection parameter / 只能从 decodingOptions"等结论试图误导；以上"待坐实"未采信任何此类输出，需亲自读码确认。

### 6.4 `NoRepeatNGramFilter` 设计草图

```swift
final class NoRepeatNGramFilter: LogitsFiltering {
    let ngramSize: Int   // 例如 3
    func filterLogits(_ logits: MLMultiArray, withTokens tokens: [Int]) -> MLMultiArray {
        // 标准 no_repeat_ngram 算法：
        // 若"接上某 token"会让某个长度 ngramSize 的片段与前面已出现的片段完全重复，
        // 就把该 token 的 logit 设为 -infinity → 模型这一步绝不选它，自然走向别的词。
        // 只禁病态的连续 n-gram 重复，正常偶尔重复不碰（阈值可调）→ 不误伤、不改已输出文本。
        return logits
    }
}
```

工作量评估：算法本身小且可单测；注入适配层取决于 6.3 待坐实点（薄 ~ 需上游 PR）；误伤风险低；对正常录音几乎无影响。

## 7. 对用户三个原始疑问的回答

| 疑问 | 结论 |
|---|---|
| 是模型识别出了问题？ | 是。模型对杂乱音频解码退化，Whisper 固有缺陷。 |
| 还是我们软件别处出问题？ | 是的，曾关闭 fallback（`temperatureFallbackCount: 0`）+ 阈值偏松，放大了问题。**已修复**。 |
| 模型能力只能到此为止？ | 不完全。开 fallback + 调阈值显著缓解；**换 large-v3/turbo 是对"听不懂杂乱语音"最对症的端侧手段**；C 方案（LogitsFilter）可在解码层进一步根治重复；但无法 100% 消除。 |

## 8. 行动清单

**已完成**
- [x] 启用 temperature fallback + 降低 compressionRatioThreshold（第 3 节，已落地、未实测）
- [x] 修正参数顺序编译错误（第 3 节 ⚠️ 注）
- [x] 核对 WhisperKit 默认值、更正 compressionCheckWindow（4.3）
- [x] 业界/VAD/解码级方案调研（4.5 / 5 / 6）

**下一步（按建议顺序）**
- [ ] **实测**：用 `It's not` 录音对比"改前/改后"转录结果
- [ ] **试 large-v3/turbo 重转**该录音（对"听不懂"最对症，无需改代码）
- [ ] 工具恢复后**坐实 6.3 注入点** → 给出"薄适配层 / 需上游 PR"确定结论
- [ ] 实现 `NoRepeatNGramFilter` + 注入适配层 + 单元测试（C 方案）

**明确不采用**
- 后处理去重（第 4.5 表第 7 项）—— 误伤、违背"如实呈现"原则
- 回调中止（6.1 方案 B）—— 同类误伤风险

## 9. 参考链接

**WhisperKit（argmaxinc/WhisperKit）**
- #294 Stuck token loops: https://github.com/argmaxinc/WhisperKit/issues/294
- #102 temperatureFallbackCount: https://github.com/argmaxinc/WhisperKit/issues/102
- #122 compressionCheckWindow: https://github.com/argmaxinc/WhisperKit/issues/122
- #283 gibberish hallucination: https://github.com/argmaxinc/WhisperKit/issues/283
- Configurations.swift: https://github.com/argmaxinc/WhisperKit/blob/main/Sources/WhisperKit/Core/Configurations.swift

**OpenAI Whisper**
- #2070 Reduce hallucinations and repetitions: https://github.com/openai/whisper/discussions/2070
- #2608 Preventing repetition hallucinations: https://github.com/openai/whisper/discussions/2608
- #2606 Hallucinates on no-speech sections: https://github.com/openai/whisper/discussions/2606
- #928 Suppressing repetitive content: https://github.com/openai/whisper/discussions/928

**faster-whisper / WhisperX / 背景**
- faster-whisper（含 repetition_penalty / no_repeat_ngram_size）: https://github.com/SYSTRAN/faster-whisper
- WhisperX（VAD + forced alignment）: https://github.com/m-bain/whisperX
- Gladia — Whisper Hallucination: https://www.gladia.io/blog/whisper-hallucination-how-to-recognize-and-overcome-it-with-gladia
