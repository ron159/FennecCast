# Implementation Plan: app-foundation

## Overview

建立 FennecCast 的独立 Git 与原生 iOS 工程基础，使一个使用显式 `AppEnvironment` 的 SwiftUI 根界面可以在 Xcode 27 下无签名构建，并让英文、简体中文资源和 XCTest 目标进入同一共享 scheme。范围严格限定在 `SPEC-app-foundation.md`，不实现播客业务。

## Architecture Decisions

- 使用检查入库的标准 `.xcodeproj` 和 shared scheme，不引入 XcodeGen、Tuist 或 CocoaPods。
- App target 使用 Swift 6 language mode、iOS 17 deployment target 和 `com.ron159.FennecCast` Bundle Identifier。
- 根界面只依赖显式创建的 `AppEnvironment`，为后续模块保留清晰组合入口。
- Foundation 阶段使用 Apple SDK 与 XCTest，不引入第三方运行时依赖。
- 本机没有 Simulator Runtime；当前门禁是通用 Simulator `build` 与 `build-for-testing`，真实 `test` 留作 Runtime 安装后的补充门禁。

## Dependency Graph

```text
approved specification
    -> repository safeguards and licensing
        -> Xcode app slice
            -> localized resources
                -> XCTest target
                    -> full foundation verification
```

## Task List

### Phase 1: Repository foundation

- [ ] Task 1: Initialize the independent repository and record approved artifacts
- [ ] Task 2: Add licensing, notices, README and repository safeguards

### Checkpoint: Repository foundation

- [ ] `git status -sb` shows only intentional FennecCast files
- [ ] `git diff --check` reports no whitespace errors
- [ ] `../AntennaPod/` has not been modified by this module

### Phase 2: Runnable app slice

- [ ] Task 3: Add the minimal SwiftUI app target and shared scheme
- [ ] Task 4: Add English and Simplified Chinese resources

### Checkpoint: Runnable app

- [ ] Generic iOS Simulator build succeeds without signing
- [ ] Root view receives an explicit `AppEnvironment`
- [ ] User-visible foundation strings come from the String Catalog

### Phase 3: Testable foundation

- [ ] Task 5: Add the XCTest target and app-foundation tests
- [ ] Task 6: Run the complete foundation verification and close the module

### Checkpoint: app-foundation complete

- [ ] Generic iOS Simulator build succeeds
- [ ] Generic iOS Simulator build-for-testing succeeds
- [ ] `swift-format lint --strict --recursive Sources Tests` succeeds
- [ ] The Git history contains small, descriptive, independently revertible commits
- [ ] Every success criterion in `SPEC-app-foundation.md` has current evidence

## Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Hand-authored Xcode project is rejected by Xcode 27 | High | Keep the project minimal and run the generic Simulator build immediately in Task 3 |
| No Simulator Runtime is installed | Medium | Compile the XCTest bundle with `build-for-testing`; do not claim runtime test execution |
| Xcode beta changes project defaults | Medium | Set deployment target, Swift version and signing behavior explicitly in checked-in build settings |
| Foundation grows into business implementation | Medium | Restrict files and acceptance criteria to `SPEC-app-foundation.md` |
| Personal signing needs a different Bundle Identifier | Low | Keep the identifier in one target build setting so it is easy to change later |

## Open Questions

- None blocking. Runtime XCTest execution remains pending until an iOS Simulator Runtime is installed.

