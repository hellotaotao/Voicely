# App Store 首次正式上架清单 (1.0.0)

背景:此前 `0.18.5` 只发过 **TestFlight**,从未在 App Store 正式发布。这是第一次走正式上架流程(不是版本更新)。

## 0. 前置确认
- [ ] App Store Connect 里已存在 Voicely 的 App 记录(TestFlight 用的就是它,通常已存在)。
- [ ] Bundle ID:`com.hellotaotao.Voicely`,Team:`CU3VTR9MRH`。
- [ ] 地区可售性(Availability):之前 TestFlight 心智是"只面向澳洲";正式版要在 **Pricing and Availability** 里明确勾选要上架的国家/地区(只勾澳洲 = 只有澳洲能搜到/下载)。

## 1. 版本与构建(代码侧)
- [x] `Config/Version.xcconfig`:`MARKETING_VERSION = 1.0.0`,`CURRENT_PROJECT_VERSION = 1`。
- [ ] 若 1.0.0 这个版本串下曾上传过 build,需把 build 号 +1(App Store Connect 卡 build 号唯一/递增)。
- [ ] Release 构建确认用 **production** APNs entitlement(当前 entitlements 文件是 development 值,Live Activities/推送要确认 Release 配置正确)。

## 2. CloudKit(数据同步)
- [ ] 若相比线上数据模型新增过 `@Model` 字段,先在 **CloudKit Console 把 Schema Deploy 到 Production**,否则 Release 写库失败、设备数据发散。
- [ ] 容器 `iCloud.com.hellotaotao.Voicely` 的 Production 环境就绪。

## 3. 文案(见 app-store-metadata.md)
- [ ] App 名称 / 副标题 / 关键词 / 描述 / 宣传文本 — 已备好,可直接拷贝。
- [ ] What's New(1.0.0)— 已备好。
- [ ] **隐私政策 URL(强制)** — 需一个可公开访问的网页。还没有则需先建。
- [ ] **技术支持 URL(强制)** — 同上。
- [ ] Copyright 署名(法律主体名)。

## 4. 截图(强制)
- [ ] iPhone 6.9"(1320 × 2868)4–6 张。
- [ ] 若勾选支持 iPad / Mac,需对应尺寸截图。
- 建议覆盖界面:录音主界面、转录列表、逐词点读转录、实时流式转录+指标卡、设置/模型管理。

## 5. App 隐私 & 合规(见 privacy-and-review-notes.md)
- [ ] App Privacy 营养标签:User Content(Audio + Other),Tracking = No。
- [ ] 导出合规:`ITSAppUsesNonExemptEncryption = false`,声明"不使用非豁免加密"。
- [ ] 年龄分级:4+。

## 6. 审核备注(强烈建议,降低被拒概率)
- [ ] 在 Review Notes 写清:首次使用需在设置里下载 WhisperKit 模型(需联网、需等待),给出操作步骤;麦克风用于录音;无需登录账号即可测试核心功能。
- [ ] 确认未登录 iCloud 时 app 不崩、可本地使用(审核机器可能没登 iCloud)。

## 7. 上传与提交
- [ ] Xcode:`Product > Archive`(scheme Voicely,Release,generic iOS device),或用已配的 fastlane(`fastlane/Fastfile`)。
- [ ] Organizer / Transporter 上传到 App Store Connect。
- [ ] ASC 里给 1.0.0 版本选中该 build → 填全字段 → **Submit for Review**。
- [ ] 选发布方式:自动发布 / 手动发布。
