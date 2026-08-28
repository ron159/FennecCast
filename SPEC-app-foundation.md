# Spec: app-foundation

## Objective

为 FennecCast 建立可独立构建、可测试、可持续扩展的原生 iOS 工程骨架。该模块只负责项目基础设施，不提前实现 Feed、播放、下载或同步业务。

用户启动应用后应看到一个使用 FennecCast 品牌、本地化正确、可进入后续功能模块的 SwiftUI 根界面。工程必须在不配置签名凭据的情况下完成通用 iOS Simulator 编译，并编译 XCTest 测试目标。

## Tech Stack

- Xcode 27.0（本机路径 `/Applications/Xcode-beta.app`）
- Swift 6.4，Swift 6 language mode
- SwiftUI、Observation、Foundation
- XCTest
- 最低部署版本 iOS 17.0
- 此模块不添加第三方依赖；GRDB 在 `local-data` 模块引入

## Commands

从 `FennecCast/` 目录运行：

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild \
  -project FennecCast.xcodeproj \
  -scheme FennecCast \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build

DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild \
  -project FennecCast.xcodeproj \
  -scheme FennecCast \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing

DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcrun swift-format \
  lint --strict --recursive Sources Tests
```

在安装 iOS Simulator Runtime 后运行：

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild \
  test \
  -project FennecCast.xcodeproj \
  -scheme FennecCast \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

## Project Structure

```text
FennecCast/
├── FennecCast.xcodeproj/
├── Sources/
│   ├── App/
│   │   ├── FennecCastApp.swift
│   │   ├── AppEnvironment.swift
│   │   └── RootView.swift
│   └── Resources/
│       ├── Assets.xcassets/
│       └── Localizable.xcstrings
├── Tests/
│   └── AppFoundationTests.swift
├── tasks/
├── LICENSE
├── THIRD_PARTY_NOTICES.md
└── README.md
```

后续模块继续在 `Sources/` 和 `Tests/` 下按 `CAPABILITY_MAP.md` 的稳定模块 ID 分目录，不创建跨平台运行时共享层。

## Code Style

- 类型使用 `UpperCamelCase`，属性与函数使用 `lowerCamelCase`。
- 优先使用不可变值和显式依赖注入。
- UI 状态限定在 `@MainActor`；并发业务服务在后续模块中使用 Actor。
- 不引入大型状态管理框架，不创建只有单一调用者的抽象层。

```swift
@MainActor
@Observable
final class AppEnvironment {
    let appName: String

    init(appName: String = "FennecCast") {
        self.appName = appName
    }
}
```

## Testing Strategy

- `AppFoundationTests` 验证默认应用环境和本地化关键值。
- `build-for-testing` 必须能编译应用与测试目标，不依赖签名账户。
- 有 Simulator Runtime 后运行完整 XCTest；当前本机没有 Runtime 时必须明确记录“仅编译测试目标”，不得声称测试已执行。
- 后续每个模块以小型单元测试为主，并在关键用户路径增加少量集成测试。

## Boundaries

- Always: 保持工程可编译；用户可见字符串进入 String Catalog；提交前检查 staged diff、敏感信息、格式和构建结果。
- Ask first: 修改最低 iOS 版本；添加白皮书未指定的第三方依赖；改变 Bundle Identifier；加入签名、推送、CloudKit 或 CI 配置。
- Never: 提交证书、Provisioning Profile、Token 或其他秘密；修改 `../AntennaPod/`；在基础模块提前实现业务功能；提交 DerivedData 或用户级 Xcode 配置。

## Success Criteria

- [x] `FennecCast.xcodeproj` 包含一个 iOS App target 和一个 XCTest target，共享 `FennecCast` scheme。
- [x] App target 最低支持 iOS 17，使用 Swift 6，并以 `FennecCast` 作为产品名。
- [x] SwiftUI 根界面可创建，英文和简体中文至少覆盖应用名称与基础状态文本。
- [x] `AppEnvironment` 通过显式初始化注入根界面。
- [x] GPL-3.0 许可证、AntennaPod 参考声明、README 和标准 Apple 构建产物忽略规则已存在。
- [x] 通用 iOS Simulator `build` 成功。
- [x] 通用 iOS Simulator `build-for-testing` 成功。
- [x] `swift-format lint --strict` 成功。
- [x] 所有变更在新的 FennecCast Git 仓库中形成独立、可回滚的原子提交。

## Verification Evidence

2026-08-28 使用 Xcode 27.0（27A5228h）验证：

- 通用 iOS Simulator `build` 成功，签名已禁用。
- 通用 iOS Simulator `build-for-testing` 成功，依赖图包含 `FennecCast` 和 `FennecCastTests`。
- `swift-format lint --strict --recursive Sources Tests` 成功。
- 产物 Bundle Identifier 为 `com.ron159.FennecCast`，最低系统版本为 iOS 17.0。
- 产物包含 `en.lproj`、`zh-Hans.lproj`、`Assets.car` 以及 arm64/x86_64 Simulator 可执行文件。
- XCTest 源码与测试 Bundle 已编译，但本机没有安装 Simulator Runtime，因此尚未执行测试用例。
- 代码质量审查覆盖正确性、简单性、架构、安全和性能，没有发现阻塞项。

## Open Questions

- 默认 Bundle Identifier 建议使用 `com.ron159.FennecCast`；个人签名时可改为你 Apple Developer 账户可用的唯一标识。
- 当前没有安装 Simulator Runtime，因此本模块首次验收只能证明 App 与测试目标可编译；安装 Runtime 后补做 XCTest 运行验证。
