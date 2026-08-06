# RaterKit

[English](README.md)

App 评分引导 + 用户反馈收集的 iOS 客户端。Swift Package，iOS 17+，纯 SwiftUI，零三方依赖。

在你自定义的时机弹出预询问；用户满意就走系统评分弹窗，不满意就打开内建反馈表单（邮箱 + 正文 + 截图 + 设备/版本信息）。

```
                        ┌──────────────┐
   你的 App ──触发──▶  │  预询问弹窗   │ ← 文案由服务端下发，改文案不用发版
                        └──────┬───────┘
                     「喜欢」   │   「不喜欢」
                   ┌───────────┴───────────┐
                   ▼                       ▼
          系统评分弹窗              内建反馈表单
      (AppStore.requestReview)   邮箱/正文/截图/设备信息
                                          │
                                          ▼
                                    rater-collector
```

服务端是一个独立仓库：**[rater-collector](https://github.com/fdddf/rater-collector)**（Cloudflare Worker + D1 + R2，自带管理后台）。先把它部署好拿到 API Key，再回来接客户端。

## 安装

`Package.swift` 或 Xcode → Add Package Dependency：

```swift
.package(url: "https://github.com/fdddf/RaterKit.git", from: "1.0.0")
```

## 用起来

```swift
import RaterKit

@main
struct MyApp: App {
    init() {
        Rater.configure(
            .init(
                // 部署 rater-collector 后 wrangler 会打印出这个地址
                endpoint: URL(string: "https://rater-collector.<你的-cf-子域>.workers.dev")!,
                appID: "my-app",
                apiKey: "rk_live_xxx",
                appStoreID: "123456789"
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView().raterPrompt()
        }
    }
}
```

在关键动作处埋点，规则满足时自动弹：

```swift
Rater.shared.record(event: "export_completed")
await Rater.shared.promptIfEligible()
```

## 四种调用姿势

```swift
await Rater.shared.promptIfEligible()     // 规则满足才弹（最常用）
Rater.shared.record(event: "export")      // 关键动作埋点
await Rater.shared.presentPrompt()        // 强制弹，绕过规则（设置页入口）
Rater.shared.presentFeedbackForm()        // 直接打开反馈表单
```

SwiftUI 挂载：根视图加 `.raterPrompt()`；想在设置页单开反馈表单用 `.raterFeedbackSheet(isPresented:)`（自带 sheet，不依赖前者）。UIKit 宿主用 `RaterUIKitPresenter`。

## 触发规则

这是主要的可定制点。所有规则**全部通过**才会弹：

```swift
Rater.configure(.init(
    endpoint: ..., appID: ..., apiKey: ...,
    rules: [
        .notAfterRated,                 // 评过就不再打扰
        .notAfterOptOut,                // 明确拒绝过就不再打扰
        .remoteEnabled,                 // 服务端可随时全量关停
        .anyOf([                        // 任一满足即可
            .event("export", atLeast: 2),
            .daysSinceInstall(atLeast: 1),
        ]),
        .maxPromptsPerVersion(1),
        .cooldown(days: 60),
        .custom("isPaidUser") { _ in Subscription.shared.isActive },
    ]
))
```

不传 `rules` 时用 `RaterConfiguration.defaultRules`：装了 3 天 + 启动过 5 次 + 本版本没弹过 + 距上次弹超过 60 天 + 没评过也没拒过 + 服务端没关停。多数工具类 app 可以直接用。

其中 `daysSinceInstall` / `launchCount` / `totalEvents` / `cooldown` / `maxPromptsPerVersion` **五条会优先读服务端下发的阈值**，代码里写的数字只是默认值 —— 这就是「不发版调触发时机」的实现方式。

调试时开 `isDebugLoggingEnabled: true`，或直接看 `evaluate()`：引擎**刻意不短路**，`TriggerDecision.blockedBy` 会一次列出所有没过的规则，而不是只报第一条。

```swift
let decision = await Rater.shared.evaluate()
print(decision.blockedBy)   // 例如 ["launchCount(atLeast: 5)", "cooldown(days: 60)"]
```

## 其它已实现的东西

- **远程配置**两层缓存（内存 + 磁盘）+ ETag + 并发合流，`configCacheTTL` 默认 6 小时
- **离线重试队列**：提交失败落盘，`NWPathMonitor` 网络恢复后自动重放，幂等 key 保证服务端不会出现重复记录，5 次后放弃
- **截图**自动降采样 + JPEG 压缩（默认长边 1600px / 质量 0.7）
- **诊断信息**采集，并在表单里对用户透明展示「将会发送什么」
- **埋点**批量上报，不含任何用户标识
- **String Catalog**（en / zh-Hans / ja / de，源语言 en）

隐私相关的三个开关都可以单独关：`collectsDiagnostics`、`isTelemetryEnabled`、`isOfflineRetryEnabled`。

## 示例 App

`Example/RaterDemo/` 是可直接跑的 SwiftUI demo，通过相对路径引用本仓库的包。设置页可以直接填 API Key 和 base URL，`configCacheTTL` 调成了 5 秒，方便在后台改完文案立刻看到效果。

```bash
cd Example/RaterDemo && xcodegen generate && open RaterDemo.xcodeproj
```

本地联调需要同时跑着服务端（在 rater-collector 仓库里 `npx wrangler dev`）。

## 测试

```bash
xcodebuild -scheme RaterKit -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

包是 iOS-only 的，`swift test` 在 macOS 宿主上跑不了，必须走模拟器。

## ⚠️ 与服务端的契约

`RaterCopy.default`（`Sources/RaterKit/Configuration/RaterConfiguration.swift`）里的兜底文案，必须和 rater-collector 仓库 `src/routes/config.ts` 里的 `FALLBACK` **逐字一致** —— 一个是客户端离线时的兜底，一个是服务端没配文案时的兜底，用户可能在两次启动间分别看到这两份，不一致会显得很奇怪。

改任何一边都要同步改另一边。这是拆成两个仓库后唯一需要人工看住的地方。

## 许可

MIT
