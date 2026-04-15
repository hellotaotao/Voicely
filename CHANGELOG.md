# Changelog

## [0.15.2] - 2026-04-15

### Bug 修复

- **录音结束后立即可见新笔记**：修复停止录音后需等待转录完成才出现新笔记的问题，现改为停止录音后立即创建并展示新 `VoiceNote`。
- **首次转录模型标识缺失**：修复新录音首次完成转录后显示 `Model Unknown` 的问题；增量转录写回文本时会同步记录 `transcriptionModelIdentifier`。

### 内部 / 维护

- **本地配置去跟踪**：停止跟踪 `.claude/settings.local.json`，并在 `.gitignore` 中忽略 `.claude/`，避免本地开发配置进入版本库。

## [0.13.0] – 2026-04-11

### 新功能

- **增量转录工作流（录音中分段转录）**：新增 `IncrementalTranscriptionCoordinator`，支持分段抽取、逐段累积转写文本，并在 `RecordingControls` 中完成 start / pause / resume / stop 全链路接入
- **录音引擎重构**：`AudioRecordingService` 改为 `AVAudioEngine + CAF(PCM)` 写入流程，停止录音后后台转换为 M4A
- **转录设置增强**：Settings 新增增量转录间隔选择（5 / 10 / 15 / 30 分钟）

### 改进

- **转录失败可见性**：界面层可展示转录重试失败，避免静默失败
- **CloudKit 同步链路整理**：替换私有同步 hook，实现更稳定的同步状态联动

### Bug 修复

- **CloudKit 重置 / 身份切换状态错误**：修复 reset 与身份变化后的状态管理问题
- **线程安全与资源泄漏**：修复 `AudioPlayerService`、`CloudStorageManager` 与录音页状态管理中的并发 / 资源问题
- **AVFAudio 并发告警**：在 `AudioRecordingService` 中将 `AVFoundation` 导入改为 `@preconcurrency import AVFoundation`，抑制模块的 Sendable 相关告警噪声
- **音频缓冲并发捕获**：将 `AVAudioConverter` 从输入回调闭包模式改为 `convert(to:from:)` 一次性转换，避免在 `@Sendable` 闭包中捕获 `AVAudioPCMBuffer`

### 测试

- 新增并完善 `IncrementalTranscriptionCoordinator` 相关测试（包含分段抽取帧数校验）
- 更新 CloudKit 相关测试以匹配新的同步实现

### 内部 / 调试

- 将分散的 `print` 调试输出统一替换为 `debugLog`，并保持 Release 构建下日志更干净

## [0.12.0] – 2026-04-05

### 新功能

- **Compute Benchmark 视图**：独立对 WhisperKit encoder / decoder 进行基准测试，支持 ANE-only、GPU-only 及 ANE|GPU 混合组合；候选录音自动过滤为 30s–5min，列表显示转录预览，整行可点击
- **WhisperKit 设备推荐视图**：内置设备性能推荐页面，并在 Settings 中提供快捷入口，帮助用户为自己的硬件选择最佳 Compute 配置

### 改进

- Compute Units 选择器改用 menu 样式，避免标签截断
- Compute Units 区域默认展开
- 更改 Compute Units 后自动提示重载模型

### Bug 修复

- **语言检测**：启用 `detectLanguage: true`，WhisperKit 现通过 prefill 自动检测语言，不再错误地默认英语
- **iCloud 重连**：`CloudStorageManager` 在 iCloud 账号变更（如启动后登录）时自动重新初始化
- **Settings 恢复入口**：模型未加载的 alert 中新增"Open Settings"按钮，用户可直接跳转修复

### 内部 / 调试

- 所有 APNs 设备 token 及 debug 日志全部用 `#if DEBUG` 包裹，防止 release 构建中泄漏
